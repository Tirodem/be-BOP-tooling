# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# registry.sh — manage /var/lib/be-BOP/tenants.tsv (tab-separated tenant registry).
#
# Schema (header row, 12 columns):
#   tenant_id       — slug, [a-z0-9][a-z0-9-]*, max 32 chars
#   domain          — full FQDN, e.g. tenant1.be-bop.dev
#   bebop_port      — local port for be-BOP HTTP (≥ 3001)
#   phoenixd_port   — local port for phoenixd HTTP API (≥ 9741)
#   mongo_port      — local port for the per-tenant mongod (≥ 27018)
#   mongodb_database — DB name on the per-tenant mongod, e.g. bebop_tenant1
#   garage_bucket   — bucket name, e.g. bebop-tenant1
#   garage_key      — Garage access key name, e.g. bebop-tenant1-key
#   bebop_version   — installed release tag (or empty until first install completes)
#   created_at      — RFC 3339 UTC timestamp of initial activation
#   status          — active | soft-deleted | archived
#   external        — 0 for internal (<tid>.<BEBOP_DNS_ZONE>) tenants,
#                     1 for --external-domain tenants (custom FQDN, DNS
#                     managed by the operator). Persisted at create time
#                     so that changing BEBOP_DNS_ZONE later doesn't
#                     silently reclassify pre-existing tenants (would
#                     leak Scaleway slots on teardown otherwise).
#
# Status semantics:
#   provisioning  — a fresh add-tenant.sh is mid-run: ports reserved,
#                   registry row exists as a placeholder, but the tenant
#                   is NOT yet operational. registry_allocate_port must
#                   consider these ports as taken. On successful
#                   completion, add-tenant.sh flips the row to `active`.
#                   On failure, the rollback undo removes the row.
#   active        — tenant is running; reserves its ports
#   soft-deleted  — services off, DNS removed, but data + config + ports preserved
#   archived      — data uploaded to SFTP and locally purged; row may be removed
#                   after retention; ports are released
#
# registry_get_status returns "absent" for tenants not present in the file;
# "absent" is never written.
#
# Concurrency: registry_lock / registry_unlock wrap an flock(2) on a sibling
# lock file. All mutations (registry_add, registry_set_field, registry_remove)
# require the caller to hold the lock.
#
# Source this AFTER lib/log.sh and lib/sudo.sh.

[[ -n "${_BEBOP_REGISTRY_SOURCED:-}" ]] && return 0
readonly _BEBOP_REGISTRY_SOURCED=1

: "${REGISTRY_PATH:=/var/lib/be-BOP/tenants.tsv}"
: "${REGISTRY_LOCK_PATH:=/var/lib/be-BOP/.tenants.tsv.lock}"
: "${REGISTRY_BEBOP_PORT_MIN:=3001}"
: "${REGISTRY_PHOENIXD_PORT_MIN:=9741}"
: "${REGISTRY_MONGO_PORT_MIN:=27018}"

readonly REGISTRY_HEADER=$'tenant_id\tdomain\tbebop_port\tphoenixd_port\tmongo_port\tmongodb_database\tgarage_bucket\tgarage_key\tbebop_version\tcreated_at\tstatus\texternal'
readonly REGISTRY_LEGACY_HEADER_11COLS=$'tenant_id\tdomain\tbebop_port\tphoenixd_port\tmongo_port\tmongodb_database\tgarage_bucket\tgarage_key\tbebop_version\tcreated_at\tstatus'
readonly REGISTRY_LEGACY_HEADER_10COLS=$'tenant_id\tdomain\tbebop_port\tphoenixd_port\tmongodb_database\tgarage_bucket\tgarage_key\tbebop_version\tcreated_at\tstatus'

_registry_col_index() {
    case "$1" in
        tenant_id)         echo 1 ;;
        domain)            echo 2 ;;
        bebop_port)        echo 3 ;;
        phoenixd_port)     echo 4 ;;
        mongo_port)        echo 5 ;;
        mongodb_database)  echo 6 ;;
        garage_bucket)     echo 7 ;;
        garage_key)        echo 8 ;;
        bebop_version)     echo 9 ;;
        created_at)        echo 10 ;;
        status)            echo 11 ;;
        external)          echo 12 ;;
        *) die "registry: unknown field '$1'" ;;
    esac
}

registry_init() {
    if [[ ! -f "$REGISTRY_PATH" ]]; then
        run_privileged install -d -m 0755 "$(dirname "$REGISTRY_PATH")"
        printf '%s\n' "$REGISTRY_HEADER" | run_privileged tee "$REGISTRY_PATH" >/dev/null
        run_privileged chmod 0644 "$REGISTRY_PATH"
        log_info "registry: created $REGISTRY_PATH"
    else
        _registry_migrate_schema_if_needed
        log_debug "registry: $REGISTRY_PATH already exists"
    fi
    if [[ ! -f "$REGISTRY_LOCK_PATH" ]]; then
        run_privileged install -d -m 0755 "$(dirname "$REGISTRY_LOCK_PATH")"
        run_privileged touch "$REGISTRY_LOCK_PATH"
        run_privileged chmod 0644 "$REGISTRY_LOCK_PATH"
    fi
}

# One-shot in-place migration from any older schema to the current 12-col
# one. Idempotent — no-op when the header already has 12 columns.
# Handles two known older shapes:
#
#   10-col (pre-mongo_port): tenant_id, domain, bebop_port, phoenixd_port,
#                            mongodb_database, garage_bucket, garage_key,
#                            bebop_version, created_at, status
#     Migration: insert `mongo_port` at position 5 (value backfilled from
#     /etc/be-BOP-mongodb/<tid>/port.env when present, else empty +
#     log_warn — an empty mongo_port breaks any future call to
#     registry_get_field <tid> mongo_port on that tenant, so operators
#     should notice and fix or purge). Then append external=0.
#
#   11-col (pre-external): all current fields except `external`.
#     Migration: append \t0 to every data row.
#
# Existing rows get external=0 (internal) — safe default: teardown will
# always attempt the upstream cleanup instead of silently skipping.
# Genuinely --external-domain tenants that predate the migration must be
# flipped to `external=1` by hand (one column edit in tenants.tsv).
_registry_migrate_schema_if_needed() {
    local current_header
    current_header=$(head -n1 "$REGISTRY_PATH" 2>/dev/null || true)
    if [[ "$current_header" == "$REGISTRY_HEADER" ]]; then
        # Header is current; still check for rows damaged by the earlier
        # buggy 10→12 migration (column shift bug — 2026-07 incident).
        _registry_repair_shifted_rows
        return 0
    fi
    if [[ "$current_header" == "$REGISTRY_LEGACY_HEADER_10COLS" ]]; then
        _registry_migrate_10_to_12
        # Same-run repair pass: in mixed-schema files (header=10 but some
        # rows already had NF=11 from an even older drift), the migration
        # would have shifted rows even with the new per-row detection.
        _registry_repair_shifted_rows
        return 0
    fi
    if [[ "$current_header" == "$REGISTRY_LEGACY_HEADER_11COLS" ]]; then
        _registry_migrate_11_to_12
        return 0
    fi
    die "registry: unknown header in $REGISTRY_PATH (expected 10/11-col legacy or 12-col current, got: '${current_header}')"
}

# Repair rows corrupted by the buggy 10→12 migration shipped in commit
# b1839ea (which assumed NF=10 for every data row and inserted a
# duplicate mongo_port when the header was 10-col but some rows had
# already drifted to NF=11 including mongo_port). Fingerprint of a
# damaged row:
#
#   - $5 numeric AND $5 == $6  (duplicate port from insert-then-shift)
#   - $11 matches ISO 8601      (was created_at, ended up as status)
#
# Reversal: drop the duplicate at $6, shift $7..$11 down by one to their
# semantic positions, and backfill $11 (status) to "active". The original
# status value was overwritten during the buggy migration and cannot be
# recovered — operators who had soft-deleted / archived tenants at the
# time of migration must re-set their status by hand after this pass.
#
# Idempotent: the fingerprint no longer matches after a repair (the new
# $5 is still numeric but the new $6 is a database name, not a port), so
# subsequent runs are no-ops.
_registry_repair_shifted_rows() {
    log_info "registry: scanning ${REGISTRY_PATH} for rows damaged by the 10→12 migration shift bug..."
    local tmp
    tmp=$(mktemp)
    # Regex written WITHOUT interval expressions ({n}, {n,m}) for
    # portability across mawk (Debian default) / gawk / busybox awk —
    # `[0-9][0-9]...` universally understood.
    #
    # Detection: compare the awk output against the source file byte
    # per byte. If they're identical, the awk touched nothing → clean.
    # If they differ, at least one row was rewritten → install the
    # patched file. cmp is used instead of an END-block sidecar counter
    # or the awk exit code (both proved fragile in earlier iterations).
    awk -F'\t' -v OFS='\t' '
        NR == 1 { print; next }
        $5 ~ /^[0-9]+$/ && $5 == $6 && $11 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ {
            print $1, $2, $3, $4, $5, $7, $8, $9, $10, $11, "active", $12
            next
        }
        { print }
    ' "$REGISTRY_PATH" > "$tmp"

    if cmp -s "$REGISTRY_PATH" "$tmp"; then
        log_info "registry: scan clean, no rows needed repair"
        rm -f "$tmp"
        return 0
    fi

    local changed_rows
    changed_rows=$(diff "$REGISTRY_PATH" "$tmp" 2>/dev/null | grep -c '^>' || true)
    run_privileged install -m 0644 "$tmp" "$REGISTRY_PATH"
    log_warn "registry: repaired ${changed_rows} row(s) damaged by the 10→12 migration shift bug — status backfilled to 'active' (original value overwritten by the bug and unrecoverable; re-set to soft-deleted/archived by hand if any of these tenants weren't active at the time)"
    rm -f "$tmp"
}

_registry_migrate_11_to_12() {
    log_info "registry: migrating $REGISTRY_PATH from 11-col to 12-col schema (adding 'external' column, default=0)"
    local tmp
    tmp=$(mktemp)
    awk -F'\t' -v OFS='\t' -v new_hdr="$REGISTRY_HEADER" '
        NR == 1 { print new_hdr; next }
        { print $0 "\t0" }
    ' "$REGISTRY_PATH" > "$tmp"
    run_privileged install -m 0644 "$tmp" "$REGISTRY_PATH"
    rm -f "$tmp"
    log_info "registry: schema migration 11→12 OK"
}

_registry_migrate_10_to_12() {
    log_info "registry: migrating $REGISTRY_PATH from 10-col (pre-mongo_port) to 12-col schema"
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$REGISTRY_HEADER" > "$tmp"
    # Per-row NF detection: the header can legitimately say 10 cols
    # while some data rows have already drifted to 11 (mongo_port
    # present in the row but not in the header — the schema drift that
    # caused the 2026-07 shift-bug incident). Handle each row on its
    # actual NF instead of forcing a rewrite based on the header.
    local row tid nf port_env mongo_port
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        tid=$(printf '%s' "$row" | cut -f1)
        nf=$(printf '%s' "$row" | awk -F'\t' '{print NF}')
        case "$nf" in
            10)
                # True 10-col row: insert backfilled mongo_port at pos 5,
                # append external=0 at pos 12.
                port_env="/etc/be-BOP-mongodb/${tid}/port.env"
                mongo_port=""
                if [[ -f "$port_env" ]]; then
                    mongo_port=$(grep -Eo '^MONGO_PORT=[0-9]+' "$port_env" 2>/dev/null | cut -d= -f2 | head -1)
                fi
                [[ -z "$mongo_port" ]] && log_warn "registry: could not backfill mongo_port for tenant '${tid}' (no ${port_env}); leaving empty"
                printf '%s' "$row" | awk -F'\t' -v OFS='\t' -v mp="$mongo_port" '
                    { print $1, $2, $3, $4, mp, $5, $6, $7, $8, $9, $10, 0 }
                ' >> "$tmp"
                ;;
            11)
                # Drift row: mongo_port already at pos 5 despite header
                # not advertising it. Just append external=0.
                log_info "registry: tenant '${tid}' row already had mongo_port (NF=11 under 10-col header); appending external=0 only"
                printf '%s\t0\n' "$row" >> "$tmp"
                ;;
            12)
                log_info "registry: tenant '${tid}' row already 12 cols; keeping as-is"
                printf '%s\n' "$row" >> "$tmp"
                ;;
            *)
                log_warn "registry: unexpected NF=${nf} for tenant '${tid}', keeping row as-is (manual repair likely needed)"
                printf '%s\n' "$row" >> "$tmp"
                ;;
        esac
    done < <(tail -n +2 "$REGISTRY_PATH")
    run_privileged install -m 0644 "$tmp" "$REGISTRY_PATH"
    rm -f "$tmp"
    log_info "registry: schema migration 10→12 OK"
}

: "${REGISTRY_LOCK_TIMEOUT_SECONDS:=120}"

# registry_lock_scope <cmd> [args...]
#
# Acquire the registry lock, run <cmd> (with args), release the lock,
# propagate the command's exit code. Preferred over manual
# lock / cmd / unlock triples: guarantees the unlock even when the
# command dies mid-run and shortens the critical section to exactly
# the operation being protected.
#
# Nesting is refused (registry_lock already dies on double-take).
registry_lock_scope() {
    registry_lock
    local rc=0
    "$@" || rc=$?
    registry_unlock
    return "$rc"
}

registry_lock() {
    if [[ -n "${_REGISTRY_FD:-}" ]]; then
        die "registry: lock already held in this process"
    fi
    exec {_REGISTRY_FD}>"$REGISTRY_LOCK_PATH"
    # Timeout observed under concurrent onboarding via test-tenant-api :
    # add-tenant.sh holds the lock for the FULL run (phases 1-14, ~40-60s)
    # because critical section wasn't narrowed. 3 orders arriving within
    # 30s made the 3rd time out at 30s. Bumped to 120s so 4-5 concurrent
    # orders can queue safely without failing. Real fix (narrow critical
    # section to registry writes only) tracked separately.
    if ! flock -x -w "$REGISTRY_LOCK_TIMEOUT_SECONDS" "$_REGISTRY_FD"; then
        die "registry: could not acquire lock on $REGISTRY_LOCK_PATH within ${REGISTRY_LOCK_TIMEOUT_SECONDS}s"
    fi
    log_debug "registry: lock acquired (fd=$_REGISTRY_FD)"
}

registry_unlock() {
    if [[ -z "${_REGISTRY_FD:-}" ]]; then
        return 0
    fi
    flock -u "$_REGISTRY_FD" 2>/dev/null || true
    eval "exec ${_REGISTRY_FD}>&-"
    unset _REGISTRY_FD
    log_debug "registry: lock released"
}

# Output the value of <field> for <tenant_id>, or empty if absent.
registry_get_field() {
    local tenant_id="$1" field="$2"
    local col
    col="$(_registry_col_index "$field")"
    awk -F'\t' -v t="$tenant_id" -v c="$col" \
        'NR>1 && $1==t { print $c; exit }' \
        "$REGISTRY_PATH"
}

# Return one of: active | soft-deleted | archived | absent.
registry_get_status() {
    local tenant_id="$1" s
    s="$(registry_get_field "$tenant_id" status)"
    if [[ -z "$s" ]]; then
        echo "absent"
    else
        echo "$s"
    fi
}

# Print all tenant_ids in the registry that match <status> (default: active).
registry_list_by_status() {
    local status="${1:-active}"
    awk -F'\t' -v s="$status" 'NR>1 && $11==s { print $1 }' "$REGISTRY_PATH"
}

# Count tenants in the registry matching <status> (default: active). Outputs
# a single integer on stdout. Used by add-tenant.sh to enforce the host-wide
# active-tenant cap (BEBOP_TENANT_CAP).
registry_count_by_status() {
    local status="${1:-active}"
    awk -F'\t' -v s="$status" 'NR>1 && $11==s { n++ } END { print n+0 }' "$REGISTRY_PATH"
}

# Allocate the smallest free port ≥ minimum, skipping ports reserved by tenants
# in states that hold their port (active, soft-deleted). Archived tenants
# release their ports.
# Args: kind = bebop | phoenixd | mongo
registry_allocate_port() {
    local kind="$1" col min_port
    case "$kind" in
        bebop)    col=3; min_port="$REGISTRY_BEBOP_PORT_MIN" ;;
        phoenixd) col=4; min_port="$REGISTRY_PHOENIXD_PORT_MIN" ;;
        mongo)    col=5; min_port="$REGISTRY_MONGO_PORT_MIN" ;;
        *) die "registry_allocate_port: unknown kind '$kind' (expected bebop|phoenixd|mongo)" ;;
    esac
    local -A used=()
    local port
    # `provisioning` counted as port-holder: a fresh add-tenant.sh that
    # just reserved its ports and wrote a placeholder row is guaranteed
    # to be seen by any concurrent add-tenant.sh looking for a free port,
    # even though the tenant isn't operational yet. Without this, two
    # parallel fresh runs racing on registry_allocate_port would both
    # get the same "next free" number and collide on bind(2) later.
    while IFS= read -r port; do
        [[ -n "$port" ]] && used["$port"]=1
    done < <(awk -F'\t' -v c="$col" \
        'NR>1 && ($11=="active" || $11=="soft-deleted" || $11=="provisioning") { print $c }' \
        "$REGISTRY_PATH")
    local p="$min_port"
    while [[ -n "${used[$p]:-}" ]]; do
        p=$((p+1))
    done
    echo "$p"
}

# Append a new row. Caller must hold the lock.
# Args (12): tenant_id domain bebop_port phoenixd_port mongo_port mongodb_database
#            garage_bucket garage_key bebop_version created_at status external
# `external` must be 0 (internal, <tid>.<zone>) or 1 (--external-domain).
registry_add() {
    if (( $# != 12 )); then
        die "registry_add: expected 12 args, got $#"
    fi
    local tenant_id="$1" status="${11}" external="${12}"
    if [[ "$external" != "0" && "$external" != "1" ]]; then
        die "registry_add: 'external' must be 0 or 1 (got '${external}')"
    fi
    local row
    row="$(IFS=$'\t'; echo "$*")"
    printf '%s\n' "$row" | run_privileged tee -a "$REGISTRY_PATH" >/dev/null
    log_info "registry: added tenant '$tenant_id' (status=$status, external=$external)"
}

# Replace the value of <field> for <tenant_id>. Caller must hold the lock.
registry_set_field() {
    local tenant_id="$1" field="$2" new_value="$3"
    local col
    col="$(_registry_col_index "$field")"
    if [[ "$(registry_get_status "$tenant_id")" == "absent" ]]; then
        die "registry_set_field: tenant '$tenant_id' not in registry"
    fi
    local tmp
    tmp="$(mktemp)"
    awk -F'\t' -v OFS='\t' -v t="$tenant_id" -v c="$col" -v v="$new_value" \
        'NR==1 { print; next }
         $1==t { $c = v; print; next }
         { print }' \
        "$REGISTRY_PATH" > "$tmp"
    run_privileged install -m 0644 "$tmp" "$REGISTRY_PATH"
    rm -f "$tmp"
    log_debug "registry: set $tenant_id.$field = '$new_value'"
}

registry_set_status() {
    registry_set_field "$1" status "$2"
}

# Remove a tenant row entirely. Caller must hold the lock.
registry_remove() {
    local tenant_id="$1"
    if [[ "$(registry_get_status "$tenant_id")" == "absent" ]]; then
        die "registry_remove: tenant '$tenant_id' not in registry"
    fi
    local tmp
    tmp="$(mktemp)"
    awk -F'\t' -v t="$tenant_id" \
        'NR==1 || $1!=t' \
        "$REGISTRY_PATH" > "$tmp"
    run_privileged install -m 0644 "$tmp" "$REGISTRY_PATH"
    rm -f "$tmp"
    log_info "registry: removed tenant '$tenant_id'"
}

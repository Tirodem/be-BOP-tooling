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
        return 0
    fi
    if [[ "$current_header" == "$REGISTRY_LEGACY_HEADER_10COLS" ]]; then
        _registry_migrate_10_to_12
        return 0
    fi
    if [[ "$current_header" == "$REGISTRY_LEGACY_HEADER_11COLS" ]]; then
        _registry_migrate_11_to_12
        return 0
    fi
    die "registry: unknown header in $REGISTRY_PATH (expected 10/11-col legacy or 12-col current, got: '${current_header}')"
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
    # Write the new header first.
    printf '%s\n' "$REGISTRY_HEADER" > "$tmp"
    # Iterate data rows and reconstruct with the two missing columns
    # inserted. Column 5 (mongo_port) is backfilled from
    # /etc/be-BOP-mongodb/<tid>/port.env if present; column 12 (external)
    # is set to 0 (internal).
    local row tid port_env mongo_port
    while IFS= read -r row; do
        # Skip empty lines (defensive).
        [[ -z "$row" ]] && continue
        tid=$(printf '%s' "$row" | cut -f1)
        port_env="/etc/be-BOP-mongodb/${tid}/port.env"
        mongo_port=""
        if [[ -f "$port_env" ]]; then
            mongo_port=$(grep -Eo '^MONGO_PORT=[0-9]+' "$port_env" 2>/dev/null | cut -d= -f2 | head -1)
        fi
        if [[ -z "$mongo_port" ]]; then
            log_warn "registry: could not backfill mongo_port for tenant '${tid}' (no ${port_env}); leaving empty — expect breakage on any port-dependent op, purge the tenant or fix the row"
        fi
        # awk with an insert-at-position pattern: fields 1..4 → same,
        # insert mongo_port, then fields 5..10 → same, then external=0.
        printf '%s' "$row" | awk -F'\t' -v OFS='\t' -v mp="$mongo_port" '
            { print $1, $2, $3, $4, mp, $5, $6, $7, $8, $9, $10, 0 }
        ' >> "$tmp"
    done < <(tail -n +2 "$REGISTRY_PATH")
    run_privileged install -m 0644 "$tmp" "$REGISTRY_PATH"
    rm -f "$tmp"
    log_info "registry: schema migration 10→12 OK"
}

registry_lock() {
    if [[ -n "${_REGISTRY_FD:-}" ]]; then
        die "registry: lock already held in this process"
    fi
    exec {_REGISTRY_FD}>"$REGISTRY_LOCK_PATH"
    if ! flock -x -w 30 "$_REGISTRY_FD"; then
        die "registry: could not acquire lock on $REGISTRY_LOCK_PATH within 30s"
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
    while IFS= read -r port; do
        [[ -n "$port" ]] && used["$port"]=1
    done < <(awk -F'\t' -v c="$col" \
        'NR>1 && ($11=="active" || $11=="soft-deleted") { print $c }' \
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

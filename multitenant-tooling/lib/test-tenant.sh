# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# test-tenant.sh — expiration tracking for ephemeral test tenants.
#
# Test tenants created via the /deploy-test-tenant webhook are tracked in a
# separate TSV file (NOT the main tenant registry, which is schema-locked at
# 11 columns) so the reaper can find which tenants are past their TTL and
# purge them. Production tenants never appear in this file.
#
# File: /var/lib/be-BOP/test-tenant-expiry.tsv
# Schema (header row, 3 columns):
#   tenant_id    — same id as in /var/lib/be-BOP/tenants.tsv
#   expires_at   — RFC 3339 UTC timestamp (e.g. 2026-06-27T14:34:56Z)
#   created_at   — RFC 3339 UTC timestamp (for diagnostics / future audit)
#
# Concurrency: protected by an flock(2) on a sibling lock file. The lock is
# distinct from the main registry lock so the reaper doesn't have to compete
# with add-tenant.sh / remove-tenant.sh for the main lock when sweeping.
#
# Source AFTER lib/log.sh and lib/sudo.sh.

[[ -n "${_BEBOP_TEST_TENANT_SOURCED:-}" ]] && return 0
readonly _BEBOP_TEST_TENANT_SOURCED=1

: "${TEST_TENANT_EXPIRY_PATH:=/var/lib/be-BOP/test-tenant-expiry.tsv}"
: "${TEST_TENANT_EXPIRY_LOCK_PATH:=/var/lib/be-BOP/.test-tenant-expiry.tsv.lock}"

readonly TEST_TENANT_EXPIRY_HEADER=$'tenant_id\texpires_at\tcreated_at'

# Initialise the expiry file + lock file if missing. Idempotent.
test_tenant_expiry_init() {
    if [[ ! -f "$TEST_TENANT_EXPIRY_PATH" ]]; then
        run_privileged install -d -m 0755 "$(dirname "$TEST_TENANT_EXPIRY_PATH")"
        printf '%s\n' "$TEST_TENANT_EXPIRY_HEADER" \
            | run_privileged tee "$TEST_TENANT_EXPIRY_PATH" >/dev/null
        run_privileged chmod 0644 "$TEST_TENANT_EXPIRY_PATH"
        log_info "test-tenant: created ${TEST_TENANT_EXPIRY_PATH}"
    fi
    if [[ ! -f "$TEST_TENANT_EXPIRY_LOCK_PATH" ]]; then
        run_privileged touch "$TEST_TENANT_EXPIRY_LOCK_PATH"
        run_privileged chmod 0644 "$TEST_TENANT_EXPIRY_LOCK_PATH"
    fi
}

test_tenant_expiry_lock() {
    if [[ -n "${_TEST_TENANT_FD:-}" ]]; then
        die "test-tenant: lock already held in this process"
    fi
    exec {_TEST_TENANT_FD}>"$TEST_TENANT_EXPIRY_LOCK_PATH"
    if ! flock -x -w 30 "$_TEST_TENANT_FD"; then
        die "test-tenant: could not acquire lock on ${TEST_TENANT_EXPIRY_LOCK_PATH} within 30s"
    fi
}

test_tenant_expiry_unlock() {
    [[ -z "${_TEST_TENANT_FD:-}" ]] && return 0
    flock -u "$_TEST_TENANT_FD" 2>/dev/null || true
    eval "exec ${_TEST_TENANT_FD}>&-"
    unset _TEST_TENANT_FD
}

# Register a new test tenant with its expiry. Caller must hold the lock.
# Args: <tenant_id> <expires_at_iso>
test_tenant_expiry_add() {
    local tenant_id="$1" expires_at="$2"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # Refuse duplicate ids — the daemon should have already checked.
    if test_tenant_expiry_get "$tenant_id" >/dev/null 2>&1; then
        die "test-tenant: '${tenant_id}' already tracked"
    fi
    local row
    row=$(printf '%s\t%s\t%s' "$tenant_id" "$expires_at" "$now")
    printf '%s\n' "$row" | run_privileged tee -a "$TEST_TENANT_EXPIRY_PATH" >/dev/null
    log_info "test-tenant: tracked '${tenant_id}' expiring at ${expires_at}"
}

# Echo "<expires_at>\t<created_at>" for the tenant, or empty if absent.
# Returns non-zero when absent so callers can branch with `if ... ; then`.
test_tenant_expiry_get() {
    local tenant_id="$1"
    local out
    out=$(awk -F'\t' -v t="$tenant_id" \
        'NR>1 && $1==t { printf "%s\t%s", $2, $3; found=1; exit } END { exit (found ? 0 : 1) }' \
        "$TEST_TENANT_EXPIRY_PATH")
    local rc=$?
    [[ -n "$out" ]] && printf '%s' "$out"
    return "$rc"
}

# Print every tracked tenant_id whose expires_at is in the past (UTC). Caller
# does NOT need to hold the lock — this is a read-only sweep.
test_tenant_expiry_list_expired() {
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    awk -F'\t' -v now="$now" \
        'NR>1 && $2 != "" && $2 < now { print $1 }' \
        "$TEST_TENANT_EXPIRY_PATH"
}

# Print every tracked tenant_id (for diagnostics / list-tenants integration).
test_tenant_expiry_list_all() {
    awk -F'\t' 'NR>1 && $1 != "" { print $1 }' "$TEST_TENANT_EXPIRY_PATH"
}

# Remove a row from the expiry registry. Caller must hold the lock. Idempotent
# (no error if the tenant isn't tracked).
test_tenant_expiry_remove() {
    local tenant_id="$1"
    local tmp
    tmp=$(mktemp)
    awk -F'\t' -v t="$tenant_id" \
        'NR==1 || $1!=t' \
        "$TEST_TENANT_EXPIRY_PATH" > "$tmp"
    run_privileged install -m 0644 "$tmp" "$TEST_TENANT_EXPIRY_PATH"
    rm -f "$tmp"
    log_debug "test-tenant: removed '${tenant_id}' from expiry tracking"
}

# Count rows (for diagnostics / cap reporting). Outputs an integer on stdout.
test_tenant_expiry_count() {
    awk -F'\t' 'NR>1 && $1 != "" { n++ } END { print n+0 }' "$TEST_TENANT_EXPIRY_PATH"
}

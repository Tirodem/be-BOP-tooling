#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# tenant-reaper.sh — purge ephemeral test tenants past their TTL.
#
# Reads /var/lib/be-BOP/test-tenant-expiry.tsv (managed by the deploy API
# daemon + this script), finds every entry whose expires_at < now, runs
# `remove-tenant.sh <id> --purge --i-know-what-im-doing --non-interactive`
# on each, then drops the row from the expiry registry on success.
#
# Designed to run unattended via systemd timer (tooling-tenant-reaper.timer,
# default 5 min cadence). Safe to run by hand too; no flags.

set -eEuo pipefail

readonly SCRIPT_NAME="tenant-reaper"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "tenant-reaper: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/tenant.sh
source "$BEBOP_TOOLING_LIB_DIR/tenant.sh"

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

main() {
    require_privileges
    test_tenant_expiry_init

    local expired_ids
    expired_ids=$(test_tenant_expiry_list_expired || true)
    if [[ -n "$expired_ids" ]]; then
        log_info "purging $(printf '%s\n' "$expired_ids" | wc -l) expired test tenant(s)"
        local id
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            log_info "purging expired test tenant '${id}'..."
            # remove-tenant.sh exits non-zero on real failure; we DO NOT
            # abort the whole sweep on one failure (another tenant may
            # still need to be reaped, and the operator is notified by
            # remove-tenant.sh's own notify_failure path). We only drop
            # the expiry row when the purge succeeded — failed entries
            # get retried on the next timer tick.
            if remove-tenant.sh "$id" --purge --i-know-what-im-doing --non-interactive; then
                test_tenant_expiry_lock
                test_tenant_expiry_remove "$id"
                test_tenant_expiry_unlock
                log_info "test-tenant: '${id}' purged + untracked"
            else
                log_error "test-tenant: purge of '${id}' failed; will retry on next sweep"
            fi
        done <<< "$expired_ids"
    else
        log_debug "no expired test tenants"
    fi

    # Post-reap orphan check. A clean reap should leave zero orphans; any
    # orphan here indicates that remove-tenant.sh left artefacts behind
    # (systemd .wants/ symlinks, nginx .bak.<ts>, etc.). We report but
    # do NOT auto-purge from the reaper — an operator should investigate
    # whether the removal path is regressing rather than silently
    # sweeping the evidence under the rug.
    local orphans_output orphans_count
    if orphans_output=$(find-orphans.sh --report 2>&1); then
        orphans_count=$(printf '%s\n' "$orphans_output" \
            | awk '/^  [a-z0-9]/{n++} END{print n+0}')
        if (( orphans_count > 0 )); then
            log_warn "post-reap orphan check: ${orphans_count} orphan(s) detected"
            notify_failure \
                "[be-BOP tooling] tenant-reaper: ${orphans_count} orphan(s) detected post-reap" \
                "The reaper finished, but find-orphans.sh reports ${orphans_count} tenant id(s) with host artefacts and no registry entry. This usually means remove-tenant.sh's teardown missed one or more artefact classes.

Full report:
${orphans_output}

Investigate remove-tenant.sh, then clean with:
  sudo find-orphans.sh --purge-all"
        fi
    else
        log_warn "post-reap orphan check: find-orphans.sh returned non-zero"
    fi
}

main "$@"

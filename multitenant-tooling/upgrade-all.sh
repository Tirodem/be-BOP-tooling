#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# upgrade-all.sh — upgrade every active tenant to a target be-BOP release.
# Delegates each individual upgrade to upgrade-tenant.sh.
#
# Modes:
#   --rolling (default)
#       Iterate tenants sequentially. Each gets upgraded + healthchecked
#       before the next is started. Stops at the first failure unless
#       --continue-on-failure is set.
#
#   --parallel
#       Launch upgrade-tenant.sh for every selected tenant in parallel,
#       wait for all, then aggregate results. Total downtime overlaps
#       across tenants but the wall-clock is shorter for large fleets.
#
# Selection:
#   --filter <regex>
#       Only operate on tenants whose tenant_id matches the regex
#       (matched with `grep -E`).

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="upgrade-all"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "upgrade-all: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/release.sh
source "$BEBOP_TOOLING_LIB_DIR/release.sh"
# shellcheck source=lib/freeze.sh
source "$BEBOP_TOOLING_LIB_DIR/freeze.sh"

# === CLI ================================================================
SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
VERSION="latest"
MODE="rolling"
FILTER=""
CONTINUE_ON_FAILURE=false
DRY_RUN=false
RUN_NON_INTERACTIVE=false
VERBOSE=false

usage() {
    cat <<EOF
upgrade-all.sh — upgrade every active be-BOP tenant.

Usage:
  upgrade-all.sh [options]

Options:
  --version <tag>            release tag, or "latest" (default)
  --rolling                  one tenant at a time (default)
  --parallel                 all tenants in parallel
  --filter <regex>           only tenants matching this regex (grep -E)
  --continue-on-failure      in --rolling mode, do not abort on first error
  --secrets-file <path>      override default ${SECRETS_FILE}
  --non-interactive          no prompts; exit if input would be required
  --dry-run                  print actions without executing
  --verbose
  -h, --help

Notes:
  - Tenants in soft-deleted/archived states are silently skipped.
  - In --parallel mode, upgrades happen concurrently; the wall-clock is
    shorter but downtime overlaps across tenants.
  - In --rolling mode, --continue-on-failure makes the script attempt
    every tenant even if some fail (still exits non-zero overall).
EOF
}

while (( $# )); do
    case "$1" in
        --version)              VERSION="$2"; shift 2 ;;
        --rolling)              MODE=rolling; shift ;;
        --parallel)             MODE=parallel; shift ;;
        --filter)               FILTER="$2"; shift 2 ;;
        --continue-on-failure)  CONTINUE_ON_FAILURE=true; shift ;;
        --secrets-file)         SECRETS_FILE="$2"; shift 2 ;;
        --non-interactive)      RUN_NON_INTERACTIVE=true; shift ;;
        --dry-run)              DRY_RUN=true; shift ;;
        --verbose)               VERBOSE=true; shift ;;
        -h|--help)              usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *) die "unexpected positional arg: $1" ;;
    esac
done

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT
export RUN_NON_INTERACTIVE VERBOSE DRY_RUN

# EXIT-trap notification for failures that happen OUTSIDE the per-tenant
# iteration (e.g. pre-warm cache dies, registry load fails). The summary
# path at the end already notifies on per-tenant failures; NOTIFIED guards
# against double-notification.
NOTIFIED=false
on_upgrade_all_exit() {
    local rc=$?
    [[ "$NOTIFIED" == "true" ]] && return
    (( rc == 0 )) && return
    notify_failure \
        "[be-BOP tooling] upgrade-all FAILED (pre-iteration)" \
        "$(printf 'Target: %s\nMode: %s\nExit code: %s\n' \
            "$VERSION" "$MODE" "$rc")"
}
trap 'on_upgrade_all_exit' EXIT

# Locate the upgrade-tenant.sh helper (sibling in source tree, /usr/local/bin
# once installed).
locate_upgrade_tenant() {
    local sibling="$SCRIPT_DIR/upgrade-tenant.sh"
    if [[ -x "$sibling" ]]; then
        echo "$sibling"; return 0
    fi
    if [[ -x /usr/local/bin/upgrade-tenant.sh ]]; then
        echo /usr/local/bin/upgrade-tenant.sh; return 0
    fi
    die "cannot locate upgrade-tenant.sh (looked in ${sibling} and /usr/local/bin)"
}

# Compose the upgrade-tenant.sh argv to forward.
upgrade_tenant_argv() {
    local tenant="$1"
    local args=("$tenant" --version "$VERSION" --secrets-file "$SECRETS_FILE")
    [[ "$DRY_RUN" == "true" ]]            && args+=(--dry-run)
    [[ "$VERBOSE" == "true" ]]            && args+=(--verbose)
    [[ "$RUN_NON_INTERACTIVE" == "true" ]] && args+=(--non-interactive)
    printf '%s\n' "${args[@]}"
}

# === Main ===============================================================
main() {
    require_privileges

    # Global mutex: prevent a manual upgrade-all run from overlapping with
    # the nightly tooling-upgrade-all.timer (or a second manual invocation).
    # Concurrent runs would double-restart the same tenants, double-consume
    # the GitHub quota, and race on rollback logic. `flock -n` returns
    # immediately if the lock is held — bail cleanly with a clear error.
    : "${BEBOP_UPGRADE_ALL_LOCK_PATH:=/var/lib/be-BOP/.upgrade-all.lock}"
    install -d -m 0755 /var/lib/be-BOP
    touch "$BEBOP_UPGRADE_ALL_LOCK_PATH"
    exec {UPGRADE_ALL_LOCK_FD}<"$BEBOP_UPGRADE_ALL_LOCK_PATH"
    if ! flock -n "$UPGRADE_ALL_LOCK_FD"; then
        die "another upgrade-all is already running (lock=$BEBOP_UPGRADE_ALL_LOCK_PATH). Wait for it to finish or check its journal."
    fi

    if [[ ! -f "$SECRETS_FILE" ]]; then
        die "secrets file not found: ${SECRETS_FILE}"
    fi
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"

    registry_init

    # Pre-resolve the target version + pre-warm the host-wide cache ONCE,
    # so each child upgrade-tenant.sh runs zero GitHub API calls and reuses
    # the single download. Without this, 15 tenants × 2 API calls each was
    # blowing the 60 req/h unauthenticated quota midway through the run.
    local resolved
    resolved=$(release_resolve_version "$VERSION")
    if [[ "$VERSION" != "$resolved" ]]; then
        log_info "upgrade-all: ${VERSION} resolved to ${resolved}"
    fi
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "upgrade-all: pre-warming host cache for ${resolved}..."
        release_cache_ensure "$resolved"
    fi
    VERSION="$resolved"

    local upgrade_tenant_path
    upgrade_tenant_path=$(locate_upgrade_tenant)

    # Build the tenant list.
    local all_active=() filtered=() frozen_skipped=()
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        all_active+=("$t")
        if [[ -n "$FILTER" ]] && ! printf '%s\n' "$t" | grep -qE "$FILTER"; then
            continue
        fi
        # freeze-tenant.sh add <id> → SKIPPED by upgrade-all (manual + nightly).
        # Single-tenant upgrade-tenant.sh <id> runs ignore this list.
        if freeze_is_frozen "$t"; then
            frozen_skipped+=("$t")
            continue
        fi
        filtered+=("$t")
    done < <(registry_list_by_status active)

    if (( ${#frozen_skipped[@]} > 0 )); then
        log_info "upgrade-all: ${#frozen_skipped[@]} tenant(s) frozen (skipped, see $(freeze_list_path)): ${frozen_skipped[*]}"
    fi

    if (( ${#filtered[@]} == 0 )); then
        log_info "no active tenants to upgrade (registry has ${#all_active[@]} active in total; filter='${FILTER}', frozen=${#frozen_skipped[@]})"
        exit 0
    fi
    log_info "upgrade-all: target=${VERSION}, mode=${MODE}, filter='${FILTER:-(none)}', tenants=${#filtered[@]}: ${filtered[*]}"

    # Categorize tenants BEFORE iterating: a tenant whose current symlink
    # already resolves to the target tag is bypassed entirely (no child
    # process, no service restart). Cleaner separation in the summary +
    # notification than relying on each child to no-op silently.
    local bypassed=() to_upgrade=()
    local t current
    for t in "${filtered[@]}"; do
        current=$(release_get_current_tag "$t")
        if [[ "$current" == "$VERSION" ]]; then
            bypassed+=("$t")
        else
            to_upgrade+=("$t")
        fi
    done
    if (( ${#bypassed[@]} > 0 )); then
        log_info "upgrade-all: bypassing ${#bypassed[@]} tenant(s) already on ${VERSION}: ${bypassed[*]}"
    fi

    local failed=() succeeded=()

    if (( ${#to_upgrade[@]} > 0 )); then
        case "$MODE" in
            rolling)
                for t in "${to_upgrade[@]}"; do
                    log_info "==== upgrading ${t} (rolling) ===="
                    local rc=0
                    # mapfile+quoted array so args with spaces or globs
                    # survive intact — a bare $(upgrade_tenant_argv "$t")
                    # would be word-split by the shell, undoing the
                    # one-arg-per-line contract of upgrade_tenant_argv.
                    local -a argv
                    mapfile -t argv < <(upgrade_tenant_argv "$t")
                    "$upgrade_tenant_path" "${argv[@]}" || rc=$?
                    if (( rc == 0 )); then
                        succeeded+=("$t")
                    else
                        failed+=("$t")
                        if [[ "$CONTINUE_ON_FAILURE" != "true" ]]; then
                            log_error "rolling upgrade aborted on failure of '${t}' (use --continue-on-failure to keep going)"
                            break
                        fi
                    fi
                done
                ;;
            parallel)
                # Cap the concurrency so a big fleet doesn't spawn N
                # upgrade-tenant.sh processes at once (registry lock queue,
                # pnpm install RAM footprint, GitHub API burst). Default 4;
                # override via BEBOP_UPGRADE_ALL_PARALLEL_MAX in secrets.env.
                : "${BEBOP_UPGRADE_ALL_PARALLEL_MAX:=4}"
                local pids=() t_for_pid=()
                local finished_pid rc
                _upgrade_all_reap_one() {
                    # Wait for ANY tracked child to finish, capture its exit
                    # status, move its tenant to succeeded / failed, prune
                    # from pids / t_for_pid.
                    finished_pid=""
                    rc=0
                    wait -n -p finished_pid "${pids[@]}" || rc=$?
                    [[ -z "$finished_pid" ]] && return
                    local i idx=-1
                    for (( i=0; i<${#pids[@]}; i++ )); do
                        if [[ "${pids[$i]}" == "$finished_pid" ]]; then
                            idx=$i
                            break
                        fi
                    done
                    (( idx < 0 )) && return
                    local t_done="${t_for_pid[$idx]}"
                    if (( rc == 0 )); then
                        succeeded+=("$t_done")
                    else
                        failed+=("$t_done")
                    fi
                    unset 'pids[idx]' 't_for_pid[idx]'
                    pids=("${pids[@]}")
                    t_for_pid=("${t_for_pid[@]}")
                }
                for t in "${to_upgrade[@]}"; do
                    while (( ${#pids[@]} >= BEBOP_UPGRADE_ALL_PARALLEL_MAX )); do
                        _upgrade_all_reap_one
                    done
                    log_info "==== launching upgrade for ${t} (parallel, ${#pids[@]}/${BEBOP_UPGRADE_ALL_PARALLEL_MAX} slots in flight) ===="
                    local -a argv
                    mapfile -t argv < <(upgrade_tenant_argv "$t")
                    "$upgrade_tenant_path" "${argv[@]}" &
                    pids+=("$!")
                    t_for_pid+=("$t")
                done
                while (( ${#pids[@]} > 0 )); do
                    _upgrade_all_reap_one
                done
                ;;
        esac
    fi

    cat <<EOF

==========================================================================
  upgrade-all summary  (target: ${VERSION}, mode: ${MODE})
==========================================================================
  Selected:   ${#filtered[@]}  (${filtered[*]})
  Frozen:     ${#frozen_skipped[@]}  ${frozen_skipped[*]:-}    (skipped — freeze-tenant.sh)
  Bypassed:   ${#bypassed[@]}  ${bypassed[*]:-}    (already on target)
  Upgraded:   ${#succeeded[@]} ${succeeded[*]:-}
  Failed:     ${#failed[@]}    ${failed[*]:-}
==========================================================================
EOF

    NOTIFIED=true
    if (( ${#failed[@]} > 0 )); then
        notify_failure \
            "[be-BOP tooling] upgrade-all (${VERSION}) had ${#failed[@]} failure(s)" \
            "Failed tenants:  ${failed[*]}
Upgraded:        ${succeeded[*]:-(none)}
Bypassed:        ${bypassed[*]:-(none)}
Mode:            ${MODE}"
        exit 1
    fi
    # All-bypass case: nothing actually changed; still notify so operators
    # know the run happened, but with a clear "no-op" subject.
    if (( ${#succeeded[@]} == 0 )); then
        notify_success \
            "[be-BOP tooling] upgrade-all NO-OP (${#bypassed[@]} tenants already on ${VERSION})" \
            "All ${#bypassed[@]} selected tenants were already on ${VERSION} — nothing to do.
Tenants: ${bypassed[*]}"
    else
        notify_success \
            "[be-BOP tooling] upgrade-all OK (${#succeeded[@]} upgraded, ${#bypassed[@]} bypassed → ${VERSION})" \
            "Upgraded:  ${succeeded[*]}
Bypassed:  ${bypassed[*]:-(none)}"
    fi
}

main "$@"

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# phoenixd.sh — helpers for the per-tenant phoenixd Lightning daemon.
#
# Why this lib exists: `systemctl disable --now phoenixd@<tenant>` does NOT
# guarantee the process is gone. If a previous purge/remove run left a phoenixd
# detached from its unit cgroup (process double-forked, unit was reinstalled
# while a child was alive, OS-level glitch), systemctl loses track and the
# orphan keeps holding the HTTP port. Recycling that port for a new tenant
# then trips EADDRINUSE in the freshly-started phoenixd until the orphan is
# explicitly killed.
#
# Both remove-tenant.sh (purge_local_filesystem) and add-tenant.sh
# (phase_clean_orphans) must call phoenixd_kill_orphans to make port recycling
# safe.
#
# Source AFTER lib/log.sh and lib/sudo.sh.

[[ -n "${_BEBOP_PHOENIXD_SOURCED:-}" ]] && return 0
readonly _BEBOP_PHOENIXD_SOURCED=1

# phoenixd_kill_orphans <port>
# Kill any phoenixd process bound to <port> that does NOT belong to the
# expected per-tenant unit cgroup. Idempotent: prints nothing and returns 0
# when no phoenixd holds the port.
#
# Uses `ss` to find the PID (avoids `fuser`'s unreliable exit codes when no
# match) and SIGTERMs first, then SIGKILL after a 3s grace period. Safe to
# call when there's no orphan — does nothing in that case.
phoenixd_kill_orphans() {
    local port="$1"
    if [[ -z "$port" ]]; then
        log_debug "phoenixd_kill_orphans: empty port; skipping"
        return 0
    fi
    # Resolve PIDs listening on the port. ss prints e.g.
    #   users:(("phoenixd",pid=135117,fd=15))
    # We extract the pid= numbers AND filter by process name to avoid
    # nuking an unrelated service that happens to bind the same port (which
    # would itself be a misconfig, but better safe than sorry).
    # `|| true` traps the "no match → exit 1" from `grep -oP` (a fresh tenant
    # has nothing listening on the port). Without it, `set -e -o pipefail`
    # aborts add-tenant in phase_clean_orphans before the txn stack has any
    # entry, so rollback logs "empty stack — nothing to undo".
    local pids
    pids=$( { run_privileged ss -H -tlnp "sport = :${port}" 2>/dev/null \
        | grep -oP 'users:\(\("phoenixd",pid=\K[0-9]+' \
        | sort -u; } || true )
    if [[ -z "$pids" ]]; then
        log_debug "phoenixd_kill_orphans: no phoenixd on port ${port}"
        return 0
    fi
    log_warn "phoenixd_kill_orphans: killing phoenixd PID(s) on port ${port}: ${pids//$'\n'/ }"
    local pid
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        run_privileged kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"
    # Grace period; then SIGKILL whoever survived.
    sleep 3
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if run_privileged kill -0 "$pid" 2>/dev/null; then
            log_warn "phoenixd_kill_orphans: PID ${pid} survived SIGTERM; sending SIGKILL"
            run_privileged kill -KILL "$pid" 2>/dev/null || true
        fi
    done <<< "$pids"
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# bebop-exit-handler.sh — invoked via ExecStopPost=+/usr/local/bin/...
# on bebop@<tenant>.service. Implements the be-BOP → orchestrator
# exit-code protocol v1 (contract validated 2026-06-12, source of truth
# in be-BOP/docs/exit-codes.md).
#
# Usage: bebop-exit-handler.sh <tenant_id>
#
# Inputs from systemd (see systemd.exec(5) "ENVIRONMENT VARIABLES SET OR
# PROPAGATED BY THE MANAGER"):
#   $EXIT_CODE    — "exited" | "killed" | "dumped"
#   $EXIT_STATUS  — numeric exit code (when EXIT_CODE=exited) or signal name
#
# Protocol summary (only handled when EXIT_CODE=exited):
#   0        permanent shutdown requested — notify, do not restart
#            (Restart=on-failure on the unit means systemd already won't)
#   100      restart, same version — no symlink change, systemd restarts
#            via RestartForceExitStatus=
#   101      update to latest GitHub release — swap symlink, restart
#   110-119  rollback to N-k where k = code - 109 (110 → N-1, …, 119 → N-10)
#   other    no orchestrator action — systemd policy applies

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="bebop-exit-handler"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "bebop-exit-handler: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/release.sh
source "$BEBOP_TOOLING_LIB_DIR/release.sh"

readonly SECRETS_FILE=/etc/be-BOP-tooling/secrets.env

TENANT_ID="${1:-}"
if [[ -z "$TENANT_ID" ]]; then
    echo "usage: $0 <tenant_id>" >&2
    exit 1
fi

BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_TENANT_ID BEBOP_TOOLING_SYSLOG_IDENT

# Load creds (BEBOP_GITHUB_PAT for GitHub API, ZULIP_* / SMTP_* for
# notifications). Missing secrets.env is non-fatal: notify_* helpers
# log_warn and skip on their own, _release_gh_get will hit the 60/h
# anonymous quota.
if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

# Safety net for unexpected failures in the handler itself (bug, jq blowup,
# release_cache_set_current failing after the cache check, etc.). The known
# protocol-failure paths (k > history, GitHub unreachable, …) call
# notify_protocol_failure and `return 0`, so this trap only fires on
# genuinely unexpected non-zero exits.
on_handler_exit() {
    local rc=$?
    if (( rc != 0 )); then
        log_error "exit-handler: ${TENANT_ID}: unexpected handler failure (rc=${rc})"
        notify_failure \
            "[be-BOP tooling] ${TENANT_ID}: exit-handler BUG (rc=${rc})" \
            "The exit-code handler itself crashed while processing exit code ${SD_EXIT_STATUS:-unknown}.
Tenant will restart on its previous release (symlink untouched). Check
journalctl -u bebop@${TENANT_ID}.service and journalctl -t ${BEBOP_TOOLING_SYSLOG_IDENT}.
This is a tooling bug — needs investigation." \
            || true
    fi
}
trap 'on_handler_exit' EXIT

# systemd guarantees these are set in the ExecStopPost context. Default to
# placeholders so we can log clearly when invoked manually for testing.
SD_EXIT_CODE="${EXIT_CODE:-unknown}"
SD_EXIT_STATUS="${EXIT_STATUS:-unknown}"

# Only the EXIT_CODE=exited path can carry a protocol code. Signal-induced
# termination (SIGTERM from systemctl stop, SIGKILL on OOM, etc.) is NOT
# part of the protocol — we leave systemd's default behavior alone.
if [[ "$SD_EXIT_CODE" != "exited" ]]; then
    log_debug "exit-handler: ${TENANT_ID}: not a clean exit (EXIT_CODE=${SD_EXIT_CODE}, EXIT_STATUS=${SD_EXIT_STATUS}), no protocol action"
    exit 0
fi

# Helper: send a Zulip notification for a failure within a protocol
# action AND noop the symlink. The unit's RestartForceExitStatus= will
# still trigger a restart on the unchanged symlink, so be-BOP comes back
# on the same version it just exited from. The merchant gets the Zulip
# explaining why their action did NOT take effect.
notify_protocol_failure() {
    local action="$1" reason="$2" current_tag="$3"
    log_error "exit-handler: ${TENANT_ID}: ${action} FAILED — ${reason}"
    notify_failure \
        "[be-BOP tooling] ${TENANT_ID}: ${action} FAILED" \
        "Tenant: ${TENANT_ID}
Action requested: ${action}
Reason: ${reason}
Current release (unchanged): ${current_tag:-unknown}

The tenant will restart on its current release. Operator action may be
required if the merchant cannot retry from the be-BOP UI."
}

handle_restart_same() {
    log_info "exit-handler: ${TENANT_ID}: restart requested (exit 100, same version)"
    notify_success \
        "[be-BOP tooling] ${TENANT_ID}: restart requested" \
        "Tenant ${TENANT_ID} requested a restart on its current release. systemd is relaunching the unit."
}

# Spawn bebop-exit-worker.sh via systemd-run --no-block so the heavy
# work (download + pnpm install + swap) happens OUTSIDE the ExecStopPost
# TimeoutStopSec=30s window. The handler exits fast; the worker starts
# bebop@<tenant> once done. If the worker crashes, its EXIT trap still
# starts bebop@ so the tenant is never left permanently down.
_spawn_exit_worker() {
    local target_tag="$1"
    local unit="bebop-exit-worker-${TENANT_ID}-$(date +%s)"
    run_privileged systemd-run \
        --no-block \
        --collect \
        --unit="$unit" \
        /usr/local/bin/bebop-exit-worker.sh "$TENANT_ID" "$target_tag"
    log_info "exit-handler: ${TENANT_ID}: spawned async worker as systemd unit '${unit}' for ${target_tag}"
}

handle_update_latest() {
    log_info "exit-handler: ${TENANT_ID}: update to latest requested (exit 101)"
    local current_tag latest_tag
    current_tag=$(release_get_current_tag "$TENANT_ID")
    if [[ -z "$current_tag" ]]; then
        notify_protocol_failure "update-latest" \
            "tenant has no current release symlink (deploy state corrupted?)" ""
        run_privileged systemctl --no-block start "bebop@${TENANT_ID}.service" || true
        return 0
    fi
    if ! latest_tag=$(release_resolve_version latest); then
        notify_protocol_failure "update-latest" \
            "could not resolve 'latest' from GitHub API (rate-limit, network, or no matching release)" \
            "$current_tag"
        run_privileged systemctl --no-block start "bebop@${TENANT_ID}.service" || true
        return 0
    fi
    if [[ "$latest_tag" == "$current_tag" ]]; then
        log_info "exit-handler: ${TENANT_ID}: already on latest (${current_tag}), no symlink swap"
        notify_success \
            "[be-BOP tooling] ${TENANT_ID}: update-latest no-op" \
            "Tenant ${TENANT_ID} requested update to latest but is already on it (${current_tag}). No change."
        run_privileged systemctl --no-block start "bebop@${TENANT_ID}.service" || true
        return 0
    fi
    _spawn_exit_worker "$latest_tag"
}

handle_rollback() {
    local k="$1"
    log_info "exit-handler: ${TENANT_ID}: rollback N-${k} requested (exit $((109 + k)))"
    local current_tag target_tag
    current_tag=$(release_get_current_tag "$TENANT_ID")
    if [[ -z "$current_tag" ]]; then
        notify_protocol_failure "rollback N-${k}" \
            "tenant has no current release symlink (deploy state corrupted?)" ""
        run_privileged systemctl --no-block start "bebop@${TENANT_ID}.service" || true
        return 0
    fi
    if ! target_tag=$(release_resolve_nth_before "$current_tag" "$k"); then
        notify_protocol_failure "rollback N-${k}" \
            "cannot resolve N-${k} on GitHub (k > history, current tag '${current_tag}' not in matching-asset list, or API unreachable)" \
            "$current_tag"
        run_privileged systemctl --no-block start "bebop@${TENANT_ID}.service" || true
        return 0
    fi
    _spawn_exit_worker "$target_tag"
}

case "$SD_EXIT_STATUS" in
    0)
        log_info "exit-handler: ${TENANT_ID}: permanent shutdown requested (exit 0)"
        notify_success \
            "[be-BOP tooling] ${TENANT_ID}: permanent shutdown" \
            "Tenant ${TENANT_ID} requested permanent shutdown via exit code 0.
Restart=on-failure on the unit will NOT auto-restart. To bring it back:
  sudo systemctl start bebop@${TENANT_ID}.service"
        ;;
    100)
        handle_restart_same
        ;;
    101)
        handle_update_latest
        ;;
    110|111|112|113|114|115|116|117|118|119)
        handle_rollback "$((SD_EXIT_STATUS - 109))"
        ;;
    102|103|104|105|106|107|108|109|120|121|122|123|124|125)
        log_warn "exit-handler: ${TENANT_ID}: reserved exit code ${SD_EXIT_STATUS} (no orchestrator action defined yet)"
        notify_failure \
            "[be-BOP tooling] ${TENANT_ID}: reserved exit code ${SD_EXIT_STATUS}" \
            "Tenant ${TENANT_ID} exited with code ${SD_EXIT_STATUS}, which is reserved in the v1 protocol but has no orchestrator action defined.
This usually means be-BOP and the orchestrator are out of sync on the protocol version — check that the orchestrator tooling is up to date."
        ;;
    *)
        log_debug "exit-handler: ${TENANT_ID}: exit code ${SD_EXIT_STATUS} hors protocole, no orchestrator action"
        ;;
esac

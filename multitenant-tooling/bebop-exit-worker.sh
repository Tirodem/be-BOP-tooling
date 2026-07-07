#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# bebop-exit-worker.sh — async worker for the be-BOP exit-code protocol.
# Spawned by bebop-exit-handler.sh via `systemd-run --no-block` so the
# heavy work (release download + pnpm install + symlink swap) is not
# bound by bebop@.service's TimeoutStopSec=30s. Whatever happens, the
# EXIT trap tries to bring bebop@ back up — so a failed download or a
# bug here can never leave a tenant permanently down.
#
# Usage: bebop-exit-worker.sh <tenant_id> <target_tag>

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="bebop-exit-worker"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "bebop-exit-worker: cannot locate lib/ directory" >&2
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
TARGET_TAG="${2:-}"

if [[ -z "$TENANT_ID" || -z "$TARGET_TAG" ]]; then
    echo "usage: $0 <tenant_id> <target_tag>" >&2
    exit 1
fi

BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_TENANT_ID BEBOP_TOOLING_SYSLOG_IDENT

if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

# Always try to bring bebop@<tenant> back up on exit — success OR failure.
# If we failed BEFORE the symlink swap, this restores the tenant on its
# previous release. If we failed AFTER, it comes back on the new release
# (which is what the operator/merchant requested).
on_worker_exit() {
    local rc=$?
    run_privileged systemctl start "bebop@${TENANT_ID}.service" 2>/dev/null || true
    if (( rc != 0 )); then
        notify_failure \
            "[be-BOP tooling] ${TENANT_ID}: exit-worker FAILED (rc=${rc})" \
            "$(printf 'Tenant: %s\nTarget release: %s\nExit code: %d\n\nTenant was restarted on its current release symlink (unchanged if failure was pre-swap).\nSee: journalctl -t %s --since "1 hour ago"\n' \
                "$TENANT_ID" "$TARGET_TAG" "$rc" "$BEBOP_TOOLING_SYSLOG_IDENT")" \
            || true
    fi
}
trap 'on_worker_exit' EXIT

log_info "worker: begin ${TENANT_ID} → ${TARGET_TAG}"

if ! release_cache_ensure "$TARGET_TAG"; then
    die "cache ensure failed for ${TARGET_TAG}"
fi

release_cache_set_current "$TENANT_ID" "$TARGET_TAG"
log_info "worker: symlink swapped to ${TARGET_TAG}"

# Explicit start (the EXIT trap also tries, but the happy path leaves a
# clean journal entry).
run_privileged systemctl start "bebop@${TENANT_ID}.service"

notify_success \
    "[be-BOP tooling] ${TENANT_ID}: applied ${TARGET_TAG}" \
    "Tenant ${TENANT_ID} now running on ${TARGET_TAG} (async post-exit worker)."

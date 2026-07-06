#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# certbot-renew-check.sh — run `certbot renew --dry-run` and notify on
# failure. Invoked by bebop-certbot-renew-check.timer (weekly) or manually.
#
# Why a separate check (vs relying on certbot's own daily timer):
# certbot's daily timer DOES renew but does NOT notify on failure — a
# broken renewal flow (vhost ACME path moved, DNS provider creds expired, etc.)
# surfaces only when a cert expires for real and the tenant tips over.
# The --dry-run exercises the full challenge flow against LE staging,
# consumes no quota, and fires Zulip + SMTP via notify_failure on any
# non-zero exit.

set -eEuo pipefail

readonly SCRIPT_NAME="certbot-renew-check"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "certbot-renew-check: cannot locate lib/ directory" >&2
    exit 1
fi

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"

readonly SECRETS_FILE=/etc/be-BOP-tooling/secrets.env

require_privileges
if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

log_info "running certbot renew --dry-run..."
rc=0
output=$(run_privileged certbot renew --dry-run 2>&1) || rc=$?

if (( rc == 0 )); then
    log_info "certbot renew --dry-run OK (no failures)"
    exit 0
fi

log_error "certbot renew --dry-run failed (rc=${rc})"
# Echo certbot's output through log_error so it lands in the per-session
# err-log (lib/log.sh) and gets auto-tailed into the notification body.
printf '%s\n' "$output" | while IFS= read -r line; do
    log_error "certbot: ${line}"
done

notify_failure \
    "[be-BOP tooling] certbot renewal check FAILED on $(hostname)" \
    "$(printf 'Weekly certbot renewal dry-run failed (rc=%s).\n\nThis means at least one cert would FAIL to renew when its actual expiry approaches.\nInvestigate now before any tenant goes down with a TLS error.\n\nManual reproduction:\n  sudo certbot renew --dry-run\n' "$rc")" \
    || true

exit "$rc"

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# certbot-renew-check.sh — run `certbot renew --dry-run` and notify on
# failure. Invoked by tooling-certbot-renew-check.timer (weekly) or manually.
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

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/dns_provider.sh
source "$BEBOP_TOOLING_LIB_DIR/dns_provider.sh"

readonly SECRETS_FILE=/etc/be-BOP-tooling/secrets.env

require_privileges
if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

# Serialize against certbot's own native timer (certbot.timer / renew).
# Without this, the two can fire the same challenge in parallel and the
# provider trips on a duplicate TXT record. The lock is the same one
# _certbot_run uses in add-tenant.sh.
: "${CERTBOT_LOCK_PATH:=/var/lib/be-BOP/.certbot.lock}"
install -d -m 0755 /var/lib/be-BOP
touch "$CERTBOT_LOCK_PATH"
exec {CERTBOT_LOCK_FD}<"$CERTBOT_LOCK_PATH"
if ! flock -n "$CERTBOT_LOCK_FD"; then
    log_info "certbot lock held by another process — deferring renew-check"
    exit 0
fi

# Pre-flight the DNS provider creds BEFORE the certbot dry-run. This
# catches a class of failure — expired API token, revoked key, wrong
# zone — that a --dry-run would still hit but with a much less clear
# error surface. We notify distinctly here so ops sees "your DNS creds
# are dead" instead of a confusing certbot ACME dump.
if ! dns_provider_ping 2>&1; then
    log_error "dns_provider_ping FAILED — DNS API creds are broken; certbot renew will fail too"
    notify_failure \
        "[be-BOP tooling] DNS provider auth FAILED on $(hostname)" \
        "$(printf 'The pre-flight dns_provider_ping run before certbot renew-check FAILED.\n\nRoot cause is almost always: DNS API token expired / revoked / wrong scope.\n\nCheck secrets.env for the active BEBOP_DNS_PROVIDER, verify its token in the provider console, and re-issue if needed. Renewals will fail until this is fixed.\n')" \
        || true
    exit 1
fi
log_info "dns_provider_ping OK — proceeding with certbot renew --dry-run"

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

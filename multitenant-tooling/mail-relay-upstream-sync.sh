#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# mail-relay-upstream-sync.sh <tenant_id>
#
# Best-effort background sync of a tenant's upstream sending domain to
# the transactional provider (Scaleway TEM in V1). Spawned as a detached
# systemd-run transient unit at the end of add-tenant.sh, so the deploy
# critical path (and the API endpoint of tenant-api.py) never waits
# on Scaleway's async DNS re-verification.
#
# Behaviour:
#   Loops up to RETRY_ATTEMPTS times (default 5) with RETRY_INTERVAL_SECONDS
#   between attempts (default 60). Each attempt:
#     1. Runs `mail-relay-ctl.sh retry-upstream <tid>`, which on first
#        iteration creates the domain upstream + publishes SPF/DKIM/DMARC/MX
#        records on the DNS provider + fires POST /check, and on
#        subsequent iterations issues POST /check + a short recheck poll.
#     2. Queries the tenant's stored upstream_domain_id via the tooling
#        MongoDB and checks the current Scaleway `status`. Exits 0 iff
#        `status == "checked"`.
#
#   If all attempts are exhausted without status=checked, exits 1 with
#   a WARN — the 15-min tooling-mail-relay-retry.timer is still there as
#   a safety net.
#
# Observability:
#   journalctl -u tooling-mail-relay-upstream-sync-<tenant_id>.service
#
# Not intended for interactive use; the operator equivalent is
# `sudo mail-relay-ctl.sh retry-upstream <tid>`.

set -eEuo pipefail

TENANT_ID="${1:?usage: mail-relay-upstream-sync.sh <tenant_id>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "mail-relay-upstream-sync: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"
# shellcheck source=lib/scaleway.sh
source "$BEBOP_TOOLING_LIB_DIR/scaleway.sh"

SECRETS_FILE="${SECRETS_FILE:-/etc/be-BOP-tooling/secrets.env}"
if [[ -r "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

BEBOP_TOOLING_SYSLOG_IDENT="tooling-mail-relay-upstream-sync"
BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
export BEBOP_TOOLING_SYSLOG_IDENT BEBOP_TOOLING_TENANT_ID

: "${RETRY_ATTEMPTS:=5}"
: "${RETRY_INTERVAL_SECONDS:=60}"
: "${BEBOP_TOOLING_MONGO_PORT:=27100}"
: "${BEBOP_TOOLING_MONGO_DB:=bebop_tooling}"

if ! mail_upstream_is_configured; then
    log_info "upstream provider not configured — exiting cleanly (nothing to sync)"
    exit 0
fi

# Fetch the tenant's upstream_domain_id from the tooling MongoDB. Empty
# when the tenant hasn't yet had a successful create call — the first
# retry-upstream attempt handles that.
_upstream_id_for_tenant() {
    local id
    id=$(run_privileged mongosh --quiet \
        --port "$BEBOP_TOOLING_MONGO_PORT" \
        --eval "var d = db.tenants.findOne({_id:'${TENANT_ID}'}); print(d && d.upstream_domain_id ? d.upstream_domain_id : '');" \
        "$BEBOP_TOOLING_MONGO_DB" 2>/dev/null | tr -d '[:space:]')
    printf '%s' "$id"
}

log_info "starting upstream sync for '${TENANT_ID}' (up to ${RETRY_ATTEMPTS} attempts × ${RETRY_INTERVAL_SECONDS}s)"

for (( attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++ )); do
    log_info "attempt ${attempt}/${RETRY_ATTEMPTS}: mail-relay-ctl retry-upstream ${TENANT_ID}"
    # retry-upstream is intentionally lenient — it may return 0 with
    # only a WARN when Scaleway responds unchecked. We rely on the
    # follow-up status check to decide whether we're done.
    mail-relay-ctl.sh retry-upstream "$TENANT_ID" || \
        log_warn "attempt ${attempt}: retry-upstream returned non-zero — will check status anyway"

    domain_id=$(_upstream_id_for_tenant)
    if [[ -z "$domain_id" ]]; then
        log_info "attempt ${attempt}: upstream_domain_id not yet stamped (Scaleway create might have failed) — will retry"
    else
        status=$(scaleway_tem_domain_status "$domain_id" 2>/dev/null || true)
        log_info "attempt ${attempt}: Scaleway status='${status:-<unknown>}' for id=${domain_id}"
        if [[ "$status" == "checked" ]]; then
            log_info "upstream validated for '${TENANT_ID}' at attempt ${attempt}"
            exit 0
        fi
    fi

    if (( attempt < RETRY_ATTEMPTS )); then
        sleep "$RETRY_INTERVAL_SECONDS"
    fi
done

log_warn "exhausted ${RETRY_ATTEMPTS} × ${RETRY_INTERVAL_SECONDS}s attempts without status=checked for '${TENANT_ID}' — tooling-mail-relay-retry.timer (15 min) will keep trying"
exit 1

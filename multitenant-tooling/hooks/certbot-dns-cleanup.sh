#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# certbot-dns-cleanup.sh — certbot --manual-cleanup-hook companion to
# certbot-dns-auth.sh. Deletes the _acme-challenge TXT record we
# published in the auth phase. Provider-agnostic (backend picked at
# runtime via DNS_PROVIDER, see lib/dns_provider.sh).
#
# Env vars provided by certbot:
#   CERTBOT_DOMAIN       e.g. tenant1.be-bop.dev or s3.tenant1.be-bop.dev
#
# Best-effort: if the record can't be found (already gone, race, etc.),
# exit 0 — we don't want to fail certbot's overall flow over a stale
# cleanup attempt.

set -eEuo pipefail

# Same as certbot-dns-auth.sh: keep certbot from labeling our normal
# log output as "error output".
exec 2>&1

: "${SECRETS_FILE:=/etc/be-BOP-tooling/secrets.env}"
: "${BEBOP_TOOLING_LIB_DIR:=/usr/local/share/be-BOP-tooling/lib}"

# shellcheck disable=SC1090
source "$SECRETS_FILE"
# shellcheck disable=SC1090
source "${BEBOP_TOOLING_LIB_DIR}/log.sh"
# shellcheck disable=SC1090
source "${BEBOP_TOOLING_LIB_DIR}/dns_provider.sh"

if [[ -z "${CERTBOT_DOMAIN:-}" || -z "${BEBOP_DNS_ZONE:-}" ]]; then
    log_warn "certbot-dns-cleanup: missing CERTBOT_DOMAIN or BEBOP_DNS_ZONE; nothing to clean"
    exit 0
fi

zone="$BEBOP_DNS_ZONE"
domain="$CERTBOT_DOMAIN"
if [[ "$domain" == "$zone" ]]; then
    sub="_acme-challenge"
elif [[ "$domain" == *".${zone}" ]]; then
    prefix="${domain%.${zone}}"
    sub="_acme-challenge.${prefix}"
else
    log_warn "certbot-dns-cleanup: domain '${domain}' not within zone '${zone}'; skipping"
    exit 0
fi

record_id=$(dns_provider_dns_record_find "$sub" TXT 2>/dev/null || true)
if [[ -z "$record_id" ]]; then
    log_info "certbot-dns-cleanup: no TXT ${sub}.${zone} found; nothing to delete"
    exit 0
fi
log_info "certbot-dns-cleanup: deleting TXT ${sub}.${zone} (id=${record_id})"
dns_provider_dns_record_delete "$record_id"
dns_provider_dns_zone_refresh

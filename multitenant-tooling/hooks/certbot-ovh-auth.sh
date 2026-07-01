#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# certbot-ovh-auth.sh — certbot --manual-auth-hook for DNS-01 via OVH.
#
# Replaces the certbot-dns-ovh Python plugin to keep the OVH API token
# scoped narrowly to a single zone (the plugin requires a broader
# /domain/* scope so it can list zones for auto-discovery; we already
# know the zone from secrets.env).
#
# certbot calls this script once per -d domain with the env vars:
#   CERTBOT_DOMAIN       e.g. tenant1.pvh-labs.com or s3.tenant1.pvh-labs.com
#   CERTBOT_VALIDATION   the TXT record value to publish
#   CERTBOT_TOKEN        (HTTP-01 only — ignored)
#
# We compute the relative subdomain inside OVH_DNS_ZONE, create the TXT
# record _acme-challenge.<sub>, refresh the zone, and sleep to let the
# record propagate to OVH's authoritative servers.

set -eEuo pipefail

# Redirect our stderr to stdout so certbot doesn't tag our log_info /
# log_warn output as "error output" (Hook ... ran with error output).
# The hook's lib/log.sh writes to stderr by convention; certbot
# captures both streams and labels stderr as errors, even when the
# exit code is 0. Merging them keeps the log content intact (still
# visible in /var/log/letsencrypt/letsencrypt.log and in journald via
# systemd-cat) without the misleading warning.
exec 2>&1

: "${SECRETS_FILE:=/etc/be-BOP-tooling/secrets.env}"
: "${BEBOP_TOOLING_LIB_DIR:=/usr/local/share/be-BOP-tooling/lib}"
# Max wait time for OVH to serve the TXT on all its authoritative NS.
# We poll actively (see poll_txt_propagation below), so this is a safety
# ceiling — typical hits are 10-30s. Previous impl slept blindly for 60s
# per SAN, doubling the cost of a 2-SAN cert (main + s3).
: "${ACME_PROPAGATION_SECONDS:=90}"

# shellcheck disable=SC1090
source "$SECRETS_FILE"
# shellcheck disable=SC1090
source "${BEBOP_TOOLING_LIB_DIR}/log.sh"
# shellcheck disable=SC1090
source "${BEBOP_TOOLING_LIB_DIR}/ovh.sh"

if [[ -z "${CERTBOT_DOMAIN:-}" || -z "${CERTBOT_VALIDATION:-}" ]]; then
    die "certbot-ovh-auth: CERTBOT_DOMAIN / CERTBOT_VALIDATION not set in env"
fi
if [[ -z "${OVH_DNS_ZONE:-}" ]]; then
    die "certbot-ovh-auth: OVH_DNS_ZONE not set in $SECRETS_FILE"
fi

zone="$OVH_DNS_ZONE"
domain="$CERTBOT_DOMAIN"
if [[ "$domain" == "$zone" ]]; then
    sub="_acme-challenge"
elif [[ "$domain" == *".${zone}" ]]; then
    prefix="${domain%.${zone}}"
    sub="_acme-challenge.${prefix}"
else
    die "certbot-ovh-auth: domain '${domain}' is not within zone '${zone}'"
fi

log_info "certbot-ovh-auth: publishing TXT ${sub}.${zone} for ACME challenge"
ovh_dns_record_create "$sub" TXT "$CERTBOT_VALIDATION" >/dev/null
ovh_dns_zone_refresh

# Actively poll OVH's authoritative NS until every one of them serves the
# TXT with the expected value, instead of a blind `sleep 60`. Cuts a fresh
# 2-SAN cert issuance (main + s3) from ~120s of blind wait to ~20-40s of
# actual propagation. Timeout guard = ACME_PROPAGATION_SECONDS.
poll_txt_propagation() {
    local fqdn="$1" expected="$2" timeout="${3:-90}"
    local nservers nservers_count deadline
    nservers=$(dig +short +time=3 +tries=1 NS "$OVH_DNS_ZONE" 2>/dev/null \
        | sed 's/\.$//' | grep -v '^$' || true)
    if [[ -z "$nservers" ]]; then
        log_warn "certbot-ovh-auth: NS lookup for '${OVH_DNS_ZONE}' failed; blind sleep ${timeout}s"
        sleep "$timeout"
        return 0
    fi
    nservers_count=$(printf '%s\n' "$nservers" | wc -l)
    log_info "certbot-ovh-auth: polling ${nservers_count} authoritative NS for TXT ${fqdn}..."
    deadline=$(( $(date +%s) + timeout ))
    local attempt=0
    while (( $(date +%s) < deadline )); do
        (( attempt++ ))
        local ns_line all_ok=1 seen=0
        while IFS= read -r ns_line; do
            [[ -z "$ns_line" ]] && continue
            # `tr -d '"'` strips the quotes dig wraps TXT values in.
            # `grep -Fx` is a fixed-string, whole-line match — no regex
            # metacharacter surprises from the ACME token.
            if dig +short +time=3 +tries=1 @"$ns_line" TXT "$fqdn" 2>/dev/null \
                | tr -d '"' | grep -Fxq "$expected"; then
                (( seen++ )) || true
            else
                all_ok=0
            fi
        done <<< "$nservers"
        if (( all_ok == 1 )); then
            log_info "certbot-ovh-auth: TXT propagated on all ${nservers_count} NS (attempt ${attempt})"
            return 0
        fi
        log_debug "certbot-ovh-auth: propagation ${seen}/${nservers_count} NS; retrying in 2s"
        sleep 2
    done
    log_warn "certbot-ovh-auth: propagation timeout after ${timeout}s (${seen}/${nservers_count} NS ready); proceeding — LE will retry"
    return 0
}

poll_txt_propagation "${sub}.${zone}" "$CERTBOT_VALIDATION" "$ACME_PROPAGATION_SECONDS"
log_info "certbot-ovh-auth: ready"

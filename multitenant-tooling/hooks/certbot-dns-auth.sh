#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# certbot-dns-auth.sh — certbot --manual-auth-hook for DNS-01, provider-
# agnostic (backend selected at runtime via DNS_PROVIDER in secrets.env,
# see lib/dns_provider.sh).
#
# Rationale: we don't use the certbot-dns-<provider> Python plugins,
# because they typically require broad API scopes for zone auto-
# discovery. We already know the zone from secrets.env (BEBOP_DNS_ZONE),
# so a narrowly-scoped token per provider suffices.
#
# certbot calls this script once per -d domain with the env vars:
#   CERTBOT_DOMAIN       e.g. tenant1.be-bop.dev or s3.tenant1.be-bop.dev
#   CERTBOT_VALIDATION   the TXT record value to publish
#   CERTBOT_TOKEN        (HTTP-01 only — ignored)
#
# We compute the relative subdomain inside BEBOP_DNS_ZONE, create the TXT
# record _acme-challenge.<sub>, refresh the zone, and poll authoritative
# NS until every one serves the TXT before returning.

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
# Max wait time for authoritative NS to serve the TXT. We poll actively
# (see poll_txt_propagation below), so this is a safety ceiling — typical
# hits are 10-30s. An earlier impl slept blindly for 60s per SAN,
# doubling the cost of a 2-SAN cert (main + s3).
: "${ACME_PROPAGATION_SECONDS:=90}"

# shellcheck disable=SC1090
source "$SECRETS_FILE"
# shellcheck disable=SC1090
source "${BEBOP_TOOLING_LIB_DIR}/log.sh"
# shellcheck disable=SC1090
source "${BEBOP_TOOLING_LIB_DIR}/dns_provider.sh"

if [[ -z "${CERTBOT_DOMAIN:-}" || -z "${CERTBOT_VALIDATION:-}" ]]; then
    die "certbot-dns-auth: CERTBOT_DOMAIN / CERTBOT_VALIDATION not set in env"
fi

# Resolve the (zone, provider) covering CERTBOT_DOMAIN — matches against
# BEBOP_DNS_ZONE (canonical) + BEBOP_DNS_EXTRA_ZONES (extras, "zone:provider"
# space-separated). Side-effects: BEBOP_DNS_ZONE + DNS_PROVIDER now reflect
# the resolved pair, and the matching backend is loaded. Dies if no zone
# matches, which lets certbot skip this cert and continue with the others
# instead of stalling the whole `certbot renew` batch.
dns_provider_resolve_for_domain "$CERTBOT_DOMAIN"

zone="$BEBOP_DNS_ZONE"
domain="$CERTBOT_DOMAIN"
if [[ "$domain" == "$zone" ]]; then
    sub="_acme-challenge"
else
    prefix="${domain%.${zone}}"
    sub="_acme-challenge.${prefix}"
fi

log_info "certbot-dns-auth: publishing TXT ${sub}.${zone} for ACME challenge"
dns_provider_dns_record_create "$sub" TXT "$CERTBOT_VALIDATION" >/dev/null
dns_provider_dns_zone_refresh

# Actively poll the authoritative NS until every one of them serves the
# TXT with the expected value, instead of a blind `sleep 60`. Cuts a fresh
# 2-SAN cert issuance (main + s3) from ~120s of blind wait to ~20-40s of
# actual propagation. Timeout guard = ACME_PROPAGATION_SECONDS.
poll_txt_propagation() {
    local fqdn="$1" expected="$2" timeout="${3:-90}"
    local nservers nservers_count deadline
    nservers=$(dig +short +time=3 +tries=1 NS "$BEBOP_DNS_ZONE" 2>/dev/null \
        | sed 's/\.$//' | grep -v '^$' || true)
    if [[ -z "$nservers" ]]; then
        log_warn "certbot-dns-auth: NS lookup for '${BEBOP_DNS_ZONE}' failed; blind sleep ${timeout}s"
        sleep "$timeout"
        return 0
    fi
    nservers_count=$(printf '%s\n' "$nservers" | wc -l)
    log_info "certbot-dns-auth: polling ${nservers_count} authoritative NS for TXT ${fqdn}..."
    deadline=$(( $(date +%s) + timeout ))
    local attempt=0
    while (( $(date +%s) < deadline )); do
        # Pre-increment: `(( expr ))` returns 1 when expr evaluates to 0,
        # and under `set -e` that kills the whole hook. `(( attempt++ ))`
        # would evaluate the PRE-value (0 on first pass) → exit 1 → hook
        # aborts before ever calling dig. `(( ++attempt ))` evaluates to
        # the NEW value (>=1), always exit 0.
        (( ++attempt ))
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
            log_info "certbot-dns-auth: TXT propagated on all ${nservers_count} NS (attempt ${attempt})"
            return 0
        fi
        log_debug "certbot-dns-auth: propagation ${seen}/${nservers_count} NS; retrying in 2s"
        sleep 2
    done
    log_warn "certbot-dns-auth: propagation timeout after ${timeout}s (${seen}/${nservers_count} NS ready); proceeding — LE will retry"
    return 0
}

poll_txt_propagation "${sub}.${zone}" "$CERTBOT_VALIDATION" "$ACME_PROPAGATION_SECONDS"
log_info "certbot-dns-auth: ready"

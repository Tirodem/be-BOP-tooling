# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# ovh.sh — OVH implementation of the dns_provider_* contract.
#
# The tooling calls DNS mutations through a provider-agnostic surface
# (dns_provider_*, see lib/dns_provider.sh). This file is one concrete
# backend; lib/infomaniak.sh is another. Selection at runtime happens via
# the `DNS_PROVIDER` env var loaded from secrets.env.
#
# Public contract implemented:
#   dns_provider_ping
#   dns_provider_is_configured
#   dns_provider_dns_record_find    <subdomain> <type>
#   dns_provider_dns_record_create  <subdomain> <type> <target> [ttl]
#   dns_provider_dns_record_delete  <record_id>
#   dns_provider_dns_zone_refresh
#
# Required env (typically loaded from /etc/be-BOP-tooling/secrets.env):
#   OVH_APPLICATION_KEY
#   OVH_APPLICATION_SECRET
#   OVH_CONSUMER_KEY
#   BEBOP_DNS_ZONE            (provider-agnostic zone name)
#
# Optional:
#   OVH_API_BASE_URL  default: https://eu.api.ovh.com/1.0
#
# Source AFTER lib/log.sh. Requires `jq` and `sha1sum` (both in coreutils/jq).

[[ -n "${_BEBOP_OVH_SOURCED:-}" ]] && return 0
readonly _BEBOP_OVH_SOURCED=1

: "${OVH_API_BASE_URL:=https://eu.api.ovh.com/1.0}"

_ovh_check_credentials() {
    local missing=()
    [[ -z "${OVH_APPLICATION_KEY:-}" ]]    && missing+=("OVH_APPLICATION_KEY")
    [[ -z "${OVH_APPLICATION_SECRET:-}" ]] && missing+=("OVH_APPLICATION_SECRET")
    [[ -z "${OVH_CONSUMER_KEY:-}" ]]       && missing+=("OVH_CONSUMER_KEY")
    if (( ${#missing[@]} )); then
        die "OVH API credentials missing: ${missing[*]} (check secrets.env)"
    fi
}

# OVH signature scheme: "$1$" + sha1_hex(secret+consumer+method+url+body+timestamp)
_ovh_signature() {
    local method="$1" url="$2" body="$3" timestamp="$4"
    local payload="${OVH_APPLICATION_SECRET}+${OVH_CONSUMER_KEY}+${method}+${url}+${body}+${timestamp}"
    local digest
    digest=$(printf '%s' "$payload" | sha1sum | cut -d' ' -f1)
    printf '$1$%s' "$digest"
}

# _ovh_api_call <METHOD> <PATH> [BODY] — internal, low-level.
_ovh_api_call() {
    local method="$1" path="$2" body="${3:-}"
    _ovh_check_credentials
    local url="${OVH_API_BASE_URL}${path}"
    local timestamp
    timestamp="$(date +%s)"
    local sig
    sig="$(_ovh_signature "$method" "$url" "$body" "$timestamp")"
    local curl_args=(
        --silent
        --show-error
        --request "$method"
        --header "X-Ovh-Application: ${OVH_APPLICATION_KEY}"
        --header "X-Ovh-Consumer: ${OVH_CONSUMER_KEY}"
        --header "X-Ovh-Timestamp: ${timestamp}"
        --header "X-Ovh-Signature: ${sig}"
        --header "Content-Type: application/json"
        --max-time 30
    )
    [[ -n "$body" ]] && curl_args+=(--data "$body")
    curl "${curl_args[@]}" "$url"
}

# === dns_provider_* contract implementation ===========================

dns_provider_is_configured() {
    [[ -n "${OVH_APPLICATION_KEY:-}" \
        && -n "${OVH_APPLICATION_SECRET:-}" \
        && -n "${OVH_CONSUMER_KEY:-}" \
        && -n "${BEBOP_DNS_ZONE:-}" ]]
}

# dns_provider_ping — verify credentials via GET /me. Logs nichandle on success.
dns_provider_ping() {
    local resp
    if ! resp=$(_ovh_api_call GET /me); then
        log_error "dns_provider(ovh): curl request failed"
        return 1
    fi
    local nic
    nic=$(printf '%s' "$resp" | jq -r '.nichandle // empty' 2>/dev/null)
    if [[ -z "$nic" ]]; then
        log_error "dns_provider(ovh): unexpected response: $(printf '%s' "$resp" | head -c 200)"
        return 1
    fi
    log_info "OVH API authenticated as nichandle '${nic}'"
}

# dns_provider_dns_record_find <subdomain> <type>
# Returns the first record id matching <subdomain> + <type>, or empty.
# Uses BEBOP_DNS_ZONE.
dns_provider_dns_record_find() {
    local subdomain="$1" rtype="$2"
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "dns_provider(ovh): BEBOP_DNS_ZONE unset"
    local resp
    resp=$(_ovh_api_call GET "/domain/zone/${BEBOP_DNS_ZONE}/record?subDomain=${subdomain}&fieldType=${rtype}")
    printf '%s' "$resp" | jq -r '.[0] // empty' 2>/dev/null
}

# dns_provider_dns_record_create <subdomain> <type> <target> [ttl=300]
# Outputs the created record id on stdout. Idempotent: if a matching record
# already exists, its id is returned without modification (use delete+create
# to change the target).
dns_provider_dns_record_create() {
    local subdomain="$1" rtype="$2" target="$3" ttl="${4:-300}"
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "dns_provider(ovh): BEBOP_DNS_ZONE unset"
    local existing
    existing=$(dns_provider_dns_record_find "$subdomain" "$rtype")
    if [[ -n "$existing" ]]; then
        log_info "dns_provider(ovh): ${subdomain}.${BEBOP_DNS_ZONE} ${rtype} record already exists (id=${existing})"
        printf '%s\n' "$existing"
        return 0
    fi
    local body
    body=$(jq -nc \
        --arg sd "$subdomain" \
        --arg rt "$rtype" \
        --arg tg "$target" \
        --argjson ttl "$ttl" \
        '{subDomain: $sd, fieldType: $rt, target: $tg, ttl: $ttl}')
    local resp
    resp=$(_ovh_api_call POST "/domain/zone/${BEBOP_DNS_ZONE}/record" "$body")
    local record_id
    record_id=$(printf '%s' "$resp" | jq -r '.id // empty')
    if [[ -z "$record_id" ]]; then
        die "dns_provider(ovh): create failed: $(printf '%s' "$resp" | head -c 300)"
    fi
    log_info "dns_provider(ovh): created ${subdomain}.${BEBOP_DNS_ZONE} ${rtype} → ${target} (id=${record_id})"
    printf '%s\n' "$record_id"
}

# dns_provider_dns_record_delete <record_id>
dns_provider_dns_record_delete() {
    local record_id="$1"
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "dns_provider(ovh): BEBOP_DNS_ZONE unset"
    [[ -z "$record_id" ]] && { log_warn "dns_provider(ovh): delete called with empty id, nothing to do"; return 0; }
    _ovh_api_call DELETE "/domain/zone/${BEBOP_DNS_ZONE}/record/${record_id}" >/dev/null
    log_info "dns_provider(ovh): deleted record id ${record_id} in zone ${BEBOP_DNS_ZONE}"
}

# dns_provider_dns_zone_refresh — push pending changes to authoritative NS.
dns_provider_dns_zone_refresh() {
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "dns_provider(ovh): BEBOP_DNS_ZONE unset"
    _ovh_api_call POST "/domain/zone/${BEBOP_DNS_ZONE}/refresh" "" >/dev/null
    log_info "dns_provider(ovh): zone ${BEBOP_DNS_ZONE} refresh requested"
}

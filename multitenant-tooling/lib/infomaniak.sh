# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# infomaniak.sh — Infomaniak implementation of the dns_provider_* contract.
#
# Selected at runtime via DNS_PROVIDER=infomaniak (see lib/dns_provider.sh).
#
# Public contract (matches lib/ovh.sh):
#   dns_provider_ping
#   dns_provider_is_configured
#   dns_provider_dns_record_find    <subdomain> <type>
#   dns_provider_dns_record_create  <subdomain> <type> <target> [ttl]
#   dns_provider_dns_record_delete  <record_id>
#   dns_provider_dns_zone_refresh
#
# Required env (typically loaded from /etc/be-BOP-tooling/secrets.env):
#   INFOMANIAK_API_TOKEN     — Personal Access Token (product = Domain / DNS)
#   BEBOP_DNS_ZONE           — provider-agnostic zone name (e.g. be-bop.dev)
#
# Optional:
#   INFOMANIAK_API_BASE_URL  default: https://api.infomaniak.com
#
# API reference: reverse-engineered from Infomaniak's public Terraform
# provider (github.com/Infomaniak/terraform-provider-infomaniak), which
# uses the same /2/zones/... endpoint tree.
#
# Source AFTER lib/log.sh. Requires `jq` and `curl`.

[[ -n "${_BEBOP_INFOMANIAK_SOURCED:-}" ]] && return 0
readonly _BEBOP_INFOMANIAK_SOURCED=1

: "${INFOMANIAK_API_BASE_URL:=https://api.infomaniak.com}"

_infomaniak_check_credentials() {
    [[ -z "${INFOMANIAK_API_TOKEN:-}" ]] \
        && die "dns_provider(infomaniak): INFOMANIAK_API_TOKEN unset (check secrets.env)"
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] \
        && die "dns_provider(infomaniak): BEBOP_DNS_ZONE unset (check secrets.env)"
}

# _infomaniak_api_call <METHOD> <PATH> [BODY]
# Outputs the raw response body on stdout. Non-2xx status codes are
# reported to stderr with the API error description (extracted from the
# {"result":"error","error":{"description":...}} envelope) and returned
# as exit 1 so callers can distinguish transport errors from API errors.
_infomaniak_api_call() {
    local method="$1" path="$2" body="${3:-}"
    _infomaniak_check_credentials
    local url="${INFOMANIAK_API_BASE_URL}${path}"
    local tmp_body tmp_status
    tmp_body=$(mktemp)
    tmp_status=$(mktemp)
    local curl_args=(
        --silent
        --show-error
        --request "$method"
        --header "Authorization: Bearer ${INFOMANIAK_API_TOKEN}"
        --header "Content-Type: application/json"
        --header "Accept: application/json"
        --max-time 30
        --write-out '%{http_code}'
        --output "$tmp_body"
    )
    [[ -n "$body" ]] && curl_args+=(--data "$body")
    local status
    status=$(curl "${curl_args[@]}" "$url" 2>"$tmp_status") || {
        local curl_err
        curl_err=$(cat "$tmp_status")
        rm -f "$tmp_body" "$tmp_status"
        log_error "dns_provider(infomaniak): curl failed: ${curl_err}"
        return 1
    }
    rm -f "$tmp_status"
    local resp
    resp=$(cat "$tmp_body")
    rm -f "$tmp_body"
    if [[ "$status" =~ ^2[0-9]{2}$ ]]; then
        printf '%s' "$resp"
        return 0
    fi
    # Non-2xx — try to extract the API error description; fall back to
    # a truncated raw body.
    local err_desc
    err_desc=$(printf '%s' "$resp" | jq -r '.error.description // empty' 2>/dev/null)
    if [[ -n "$err_desc" ]]; then
        log_error "dns_provider(infomaniak): ${method} ${path} → HTTP ${status}: ${err_desc}"
    else
        log_error "dns_provider(infomaniak): ${method} ${path} → HTTP ${status}: $(printf '%s' "$resp" | head -c 300)"
    fi
    return 1
}

# === dns_provider_* contract implementation ===========================

dns_provider_is_configured() {
    [[ -n "${INFOMANIAK_API_TOKEN:-}" && -n "${BEBOP_DNS_ZONE:-}" ]]
}

# dns_provider_ping — verify creds + zone existence via GET /2/zones/<zone>.
# Success = 2xx + result:"success"; anything else surfaces as error.
dns_provider_ping() {
    local resp
    if ! resp=$(_infomaniak_api_call GET "/2/zones/${BEBOP_DNS_ZONE}"); then
        return 1
    fi
    local result fqdn
    result=$(printf '%s' "$resp" | jq -r '.result // empty' 2>/dev/null)
    fqdn=$(printf '%s' "$resp" | jq -r '.data.fqdn // empty' 2>/dev/null)
    if [[ "$result" != "success" ]]; then
        log_error "dns_provider(infomaniak): GET zone did not return result:success (${result:-<empty>})"
        return 1
    fi
    log_info "Infomaniak API authenticated; zone '${fqdn:-$BEBOP_DNS_ZONE}' reachable"
}

# dns_provider_dns_record_find <subdomain> <type>
# Returns the first record id matching source=<subdomain> + type=<type>,
# or empty. Infomaniak has no /records?source=... filter; we pull the
# whole zone (with records inline) and filter client-side. Fine at
# tenant fleet sizes — the zone is our own, we don't share it.
dns_provider_dns_record_find() {
    local subdomain="$1" rtype="$2"
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "dns_provider(infomaniak): BEBOP_DNS_ZONE unset"
    local resp
    resp=$(_infomaniak_api_call GET "/2/zones/${BEBOP_DNS_ZONE}?with=records") || return 1
    printf '%s' "$resp" \
        | jq -r --arg sd "$subdomain" --arg rt "$rtype" \
            '.data.records[]? | select(.source == $sd and .type == $rt) | .id' 2>/dev/null \
        | head -1
}

# dns_provider_dns_record_create <subdomain> <type> <target> [ttl=300]
# Outputs the created record id on stdout. Idempotent: an existing
# matching record's id is returned unchanged (mirrors ovh.sh's behavior;
# use delete+create to change the target).
dns_provider_dns_record_create() {
    local subdomain="$1" rtype="$2" target="$3" ttl="${4:-300}"
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "dns_provider(infomaniak): BEBOP_DNS_ZONE unset"
    local existing
    existing=$(dns_provider_dns_record_find "$subdomain" "$rtype") || return 1
    if [[ -n "$existing" ]]; then
        log_info "dns_provider(infomaniak): ${subdomain}.${BEBOP_DNS_ZONE} ${rtype} record already exists (id=${existing})"
        printf '%s\n' "$existing"
        return 0
    fi
    local body
    body=$(jq -nc \
        --arg t "$rtype" \
        --arg s "$subdomain" \
        --arg tg "$target" \
        --argjson ttl "$ttl" \
        '{type: $t, source: $s, target: $tg, ttl: $ttl}')
    local resp
    resp=$(_infomaniak_api_call POST "/2/zones/${BEBOP_DNS_ZONE}/records" "$body") || return 1
    local record_id
    record_id=$(printf '%s' "$resp" | jq -r '.data.id // empty' 2>/dev/null)
    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        die "dns_provider(infomaniak): create returned no record id: $(printf '%s' "$resp" | head -c 300)"
    fi
    log_info "dns_provider(infomaniak): created ${subdomain}.${BEBOP_DNS_ZONE} ${rtype} → ${target} (id=${record_id})"
    printf '%s\n' "$record_id"
}

# dns_provider_dns_record_delete <record_id>
dns_provider_dns_record_delete() {
    local record_id="$1"
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "dns_provider(infomaniak): BEBOP_DNS_ZONE unset"
    [[ -z "$record_id" ]] && { log_warn "dns_provider(infomaniak): delete called with empty id, nothing to do"; return 0; }
    _infomaniak_api_call DELETE "/2/zones/${BEBOP_DNS_ZONE}/records/${record_id}" >/dev/null || return 1
    log_info "dns_provider(infomaniak): deleted record id ${record_id} in zone ${BEBOP_DNS_ZONE}"
}

# dns_provider_dns_zone_refresh — no-op on Infomaniak.
#
# OVH exposes an explicit /refresh endpoint because zone edits stay in
# an editor buffer until pushed to the authoritative servers. Infomaniak
# propagates every mutation immediately (confirmed against the public
# Terraform provider's client, which never calls a refresh endpoint).
# We keep the function so the caller code is provider-agnostic — it just
# logs at debug level and returns.
dns_provider_dns_zone_refresh() {
    log_debug "dns_provider(infomaniak): zone_refresh is a no-op (mutations propagate immediately)"
    return 0
}

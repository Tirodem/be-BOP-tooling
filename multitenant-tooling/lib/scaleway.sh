# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# scaleway.sh — thin client over the Scaleway Transactional Email API.
#
# We only need what `add-tenant.sh` / `remove-tenant.sh` need to register a
# tenant's send-only sub-domain:
#   - declare a new sending domain (POST /domains) → get the DKIM public key
#     and DNS record checklist
#   - get status / DNS record specs (GET /domains/{id})
#   - delete a domain (POST /domains/{id}/delete)
#
# The transactional-email API surface is much larger (templates, blocklists,
# webhooks, statistics). We deliberately stop at what the provisioning path
# needs — anything more is provider-agnostic-breaking design creep.
#
# Env vars (from /etc/be-BOP-tooling/secrets.env):
#   SCALEWAY_TEM_API_KEY        Scaleway IAM API key (X-Auth-Token). Required.
#   SCALEWAY_TEM_PROJECT_ID     UUID of the Scaleway project holding TEM.
#   SCALEWAY_TEM_REGION         Default "fr-par" (only region TEM ships in).
#
# Source AFTER lib/log.sh (uses log_info / log_warn / die from there).
# Requires: curl, jq (already host deps of the rest of the tooling).

[[ -n "${_BEBOP_SCALEWAY_SOURCED:-}" ]] && return 0
readonly _BEBOP_SCALEWAY_SOURCED=1

: "${SCALEWAY_TEM_API_BASE:=https://api.scaleway.com/transactional-email/v1alpha1}"
: "${SCALEWAY_TEM_REGION:=fr-par}"

_scaleway_require() {
    [[ -z "${SCALEWAY_TEM_API_KEY:-}" ]] \
        && die "scaleway: SCALEWAY_TEM_API_KEY unset in secrets.env"
    [[ -z "${SCALEWAY_TEM_PROJECT_ID:-}" ]] \
        && die "scaleway: SCALEWAY_TEM_PROJECT_ID unset in secrets.env"
}

# _scaleway_api <method> <path> [body_json]
# On success (2xx), prints the raw response body to stdout.
# On failure, returns the HTTP status via return code (mapped to 1..255)
# and prints response body to stderr for diagnostics.
_scaleway_api() {
    local method="$1" path="$2" body="${3:-}"
    _scaleway_require
    local url="${SCALEWAY_TEM_API_BASE}${path}"
    local tmpout tmpstatus
    tmpout=$(mktemp)
    tmpstatus=$(mktemp)
    local curl_args=(
        -sS
        -X "$method"
        -H "X-Auth-Token: ${SCALEWAY_TEM_API_KEY}"
        -H "Content-Type: application/json"
        -o "$tmpout"
        -w '%{http_code}'
        --max-time 30
    )
    [[ -n "$body" ]] && curl_args+=(--data "$body")
    curl "${curl_args[@]}" "$url" > "$tmpstatus"
    local status
    status=$(<"$tmpstatus")
    rm -f "$tmpstatus"
    if [[ "$status" =~ ^2 ]]; then
        cat "$tmpout"
        rm -f "$tmpout"
        return 0
    fi
    # Non-2xx: dump body to stderr, distinguish rate limit / not-found
    # so callers can react without re-parsing.
    log_warn "scaleway: ${method} ${path} → HTTP ${status}: $(head -c 300 "$tmpout")"
    rm -f "$tmpout"
    case "$status" in
        404) return 44 ;;      # not found
        409) return 49 ;;      # already exists / conflict
        429) return 29 ;;      # rate limited
        [45]*) return 40 ;;    # generic 4xx/5xx failure
        *)    return 1 ;;
    esac
}

# scaleway_tem_domain_create <full_domain_name>
#
# Idempotent: if the domain already exists in the project (HTTP 409), we
# fetch its id via list + filter and return that.
#
# Prints the domain id (a UUID) on stdout on success.
scaleway_tem_domain_create() {
    local full_domain="$1"
    [[ -z "$full_domain" ]] && die "scaleway_tem_domain_create: domain name required"
    local body resp
    body=$(jq -nc \
        --arg dn "$full_domain" \
        --arg pid "$SCALEWAY_TEM_PROJECT_ID" \
        '{domain_name: $dn, project_id: $pid, autoconfig: false}')
    if resp=$(_scaleway_api POST \
            "/regions/${SCALEWAY_TEM_REGION}/domains" "$body"); then
        local id
        id=$(printf '%s' "$resp" | jq -r '.id // empty')
        [[ -z "$id" ]] && die "scaleway_tem_domain_create: response missing id: ${resp:0:300}"
        log_info "scaleway: domain '${full_domain}' created (id=${id})"
        printf '%s\n' "$id"
        return 0
    fi
    # Conflict → domain already exists in this project. Look it up.
    if [[ $? -eq 49 ]]; then
        local existing
        existing=$(scaleway_tem_domain_find "$full_domain")
        [[ -z "$existing" ]] && die "scaleway_tem_domain_create: 409 but domain not found on lookup"
        log_info "scaleway: domain '${full_domain}' already registered (id=${existing})"
        printf '%s\n' "$existing"
        return 0
    fi
    die "scaleway_tem_domain_create: could not create '${full_domain}' (see previous WARN)"
}

# scaleway_tem_domain_find <full_domain_name>
# Prints the domain id on stdout, or empty if not found.
scaleway_tem_domain_find() {
    local full_domain="$1"
    _scaleway_require
    local encoded
    encoded=$(printf '%s' "$full_domain" | jq -sRr @uri)
    local resp
    resp=$(_scaleway_api GET \
        "/regions/${SCALEWAY_TEM_REGION}/domains?project_id=${SCALEWAY_TEM_PROJECT_ID}&name=${encoded}") \
        || return 1
    printf '%s' "$resp" | jq -r --arg dn "$full_domain" \
        '.domains[]? | select(.name == $dn) | .id' | head -n1
}

# scaleway_tem_domain_get <domain_id>
# Prints the full domain object (JSON) on stdout.
scaleway_tem_domain_get() {
    local id="$1"
    [[ -z "$id" ]] && die "scaleway_tem_domain_get: id required"
    _scaleway_api GET "/regions/${SCALEWAY_TEM_REGION}/domains/${id}"
}

# scaleway_tem_domain_dkim_public_key <domain_id>
# Extracts the DKIM public key from the domain object. Empty output means
# the value is not yet populated (Scaleway occasionally provisions it a
# few seconds after the domain create call). Callers can poll.
scaleway_tem_domain_dkim_public_key() {
    local id="$1"
    scaleway_tem_domain_get "$id" \
        | jq -r '.dkim_config.public_key // .dkim.public_key // empty'
}

# scaleway_tem_domain_dns_records <domain_id>
# Prints the raw records JSON from the /records sub-resource. The exact
# shape isn't documented here on purpose — the caller (add-tenant.sh)
# only needs SPF / DKIM / DMARC values, extracted with .type filters.
scaleway_tem_domain_dns_records() {
    local id="$1"
    [[ -z "$id" ]] && die "scaleway_tem_domain_dns_records: id required"
    _scaleway_api GET "/regions/${SCALEWAY_TEM_REGION}/domains/${id}"
}

# scaleway_tem_domain_delete <domain_id>
# Best-effort: 404 is treated as success (already deleted).
scaleway_tem_domain_delete() {
    local id="$1"
    [[ -z "$id" ]] && { log_warn "scaleway_tem_domain_delete: empty id, skipping"; return 0; }
    if _scaleway_api POST \
            "/regions/${SCALEWAY_TEM_REGION}/domains/${id}/delete" >/dev/null; then
        log_info "scaleway: domain id=${id} deleted"
        return 0
    fi
    local rc=$?
    if (( rc == 44 )); then
        log_info "scaleway: domain id=${id} already gone (404)"
        return 0
    fi
    log_warn "scaleway: delete of id=${id} failed (rc=${rc}); leaving to next reconcile"
    return "$rc"
}

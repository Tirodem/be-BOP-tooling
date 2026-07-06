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
    # Same $? trap as scaleway_tem_domain_delete: capture rc immediately
    # (assignment failure via `local rc=$?` right after `if ...; fi`
    # returns 0 for a non-taken then-branch and hid every 409 conflict).
    resp=$(_scaleway_api POST \
            "/regions/${SCALEWAY_TEM_REGION}/domains" "$body")
    local rc=$?
    if (( rc == 0 )); then
        local id
        id=$(printf '%s' "$resp" | jq -r '.id // empty')
        [[ -z "$id" ]] && die "scaleway_tem_domain_create: response missing id: ${resp:0:300}"
        log_info "scaleway: domain '${full_domain}' created (id=${id})"
        printf '%s\n' "$id"
        return 0
    fi
    # Conflict → domain already exists in this project. Look it up.
    if (( rc == 49 )); then
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

# scaleway_tem_domain_check <domain_id>
# Trigger a Scaleway-side DNS re-verification of a domain. After we've
# published SPF / DKIM / DMARC on the DNS provider, this tells Scaleway
# to re-query and flip the domain from status="unchecked" to "checked".
# Without triggering it, Scaleway's next auto-check runs on a schedule we
# don't control (empirically hours), and any MAIL FROM before then is
# rejected with `551 5.5.3 Domain name '...' must be added, and validated
# before using it`.
scaleway_tem_domain_check() {
    local id="$1"
    [[ -z "$id" ]] && die "scaleway_tem_domain_check: id required"
    _scaleway_api POST "/regions/${SCALEWAY_TEM_REGION}/domains/${id}/check" ""
}

# scaleway_tem_domain_status <domain_id>
# Prints the current status string ("unchecked" | "checked" | ...).
scaleway_tem_domain_status() {
    local id="$1"
    [[ -z "$id" ]] && die "scaleway_tem_domain_status: id required"
    scaleway_tem_domain_get "$id" | jq -r '.status // empty'
}

# scaleway_tem_domain_delete <domain_id>
# Best-effort: 404 is treated as success (already gone).
#
# The verb on Scaleway's TEM API is `revoke`, not `delete` (the /delete
# path returns 404). Revoke marks the domain as gone and — per Scaleway
# doc — releases the slot in the plan's domain quota.
scaleway_tem_domain_delete() {
    local id="$1"
    [[ -z "$id" ]] && { log_warn "scaleway_tem_domain_delete: empty id, skipping"; return 0; }
    # Capturing $? via `local rc=$?` AFTER an `if cmd; then ...; fi`
    # block yields 0 when cmd failed and no branch executed (bash
    # returns 0 for a "successfully evaluated but false" if statement),
    # which used to swallow every non-2xx as if it were a success.
    # Capture rc immediately from the command instead.
    _scaleway_api POST "/regions/${SCALEWAY_TEM_REGION}/domains/${id}/revoke" "" >/dev/null
    local rc=$?
    if (( rc == 0 )); then
        log_info "scaleway: domain id=${id} revoked"
        return 0
    fi
    if (( rc == 44 )); then
        log_info "scaleway: domain id=${id} already gone (404)"
        return 0
    fi
    log_warn "scaleway: revoke of id=${id} failed (rc=${rc}); leaving to next reconcile"
    return "$rc"
}

# === Provider-agnostic surface ==========================================
#
# The rest of the tooling talks to `mail_upstream_*` only. Everything below
# is what a hypothetical second provider (Mailgun, Postmark…) would need to
# reimplement in its own adapter lib. The names, argument order and stdout
# format below are the contract; the Scaleway-specific implementation is
# above.

# mail_upstream_is_configured
# Return 0 iff the upstream adapter has the credentials it needs to talk
# to its provider. Callers (retry-upstream, remove-tenant) use this to
# noop silently when the operator hasn't set up an upstream yet — the
# fake SMTP itself works standalone.
mail_upstream_is_configured() {
    [[ -n "${SCALEWAY_TEM_API_KEY:-}" && -n "${SCALEWAY_TEM_PROJECT_ID:-}" ]]
}

# mail_upstream_setup_domain <tenant_subdomain_label> <full_domain>
#
# End-to-end registration for one tenant's sending domain:
#   1. Register the domain with the upstream provider.
#   2. Wait for DKIM material to be available.
#   3. Post SPF / DKIM / DMARC records in our DNS zone via lib/dns_provider.sh
#      (the caller must have sourced lib/dns_provider.sh and BEBOP_DNS_ZONE must
#      match the parent zone of <full_domain>).
#
# Prints the upstream provider's internal domain id on stdout on success —
# the caller stores it via `mail-relay-ctl set-upstream-id`. Returns
# non-zero on any failure with a WARN log; callers treat this as
# "not this tick" and the retry timer picks it up next round.
mail_upstream_setup_domain() {
    local subdomain_label="$1" full_domain="$2"
    [[ -z "$subdomain_label" || -z "$full_domain" ]] \
        && { log_error "mail_upstream_setup_domain: both args required"; return 2; }
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] \
        && { log_error "mail_upstream_setup_domain: BEBOP_DNS_ZONE unset"; return 2; }

    # 1. Create (idempotent). Capture stderr → surface HTTP error verbatim.
    local domain_id create_err
    create_err=$(mktemp)
    if ! domain_id=$(scaleway_tem_domain_create "$full_domain" 2>"$create_err"); then
        local err_snippet
        err_snippet=$(cat "$create_err")
        rm -f "$create_err"
        log_warn "mail_upstream_setup_domain: provider registration failed for '${full_domain}': ${err_snippet:-<no stderr>}"
        return 1
    fi
    rm -f "$create_err"

    # 2. Fetch the domain object. Its `records` map contains the SPF /
    # DKIM / DMARC values ready to publish — Scaleway derives DKIM
    # selector from the project UUID (e.g. "<uuid>._domainkey.<domain>"),
    # NOT a fixed "scw._domainkey", so we can't hardcode names. We read
    # each record's `name` + `value` verbatim from the response.
    local dom_json get_err
    get_err=$(mktemp)
    if ! dom_json=$(scaleway_tem_domain_get "$domain_id" 2>"$get_err"); then
        local err_snippet
        err_snippet=$(cat "$get_err")
        rm -f "$get_err"
        log_warn "mail_upstream_setup_domain: could not fetch records for '${full_domain}' (id=${domain_id}): ${err_snippet:-<no stderr>}"
        return 1
    fi
    rm -f "$get_err"

    # 3. For each of spf / dkim / dmarc: extract name+value from
    # `.records.<type>`, strip trailing dot, strip the parent zone suffix
    # to get the local label, publish as TXT via lib/dns_provider.sh.
    # MX from Scaleway is ignored — the relay only sends outbound; we
    # don't accept incoming mail on tenant subdomains.
    local zone="$BEBOP_DNS_ZONE"
    local rtype rname rval label
    for rtype in spf dkim dmarc; do
        rname=$(printf '%s' "$dom_json" | jq -r ".records.${rtype}.name // empty")
        rval=$(printf '%s' "$dom_json" | jq -r ".records.${rtype}.value // empty")
        if [[ -z "$rname" || -z "$rval" ]]; then
            log_warn "mail_upstream_setup_domain: Scaleway response missing records.${rtype} for '${full_domain}' — will retry"
            return 1
        fi
        # Strip trailing dot (FQDN → dotless). Strip the zone suffix
        # (with its leading dot) to keep only the local label, which is
        # what dns_provider_dns_record_create expects. If the record is
        # AT the zone apex it's an error here — TEM records always live
        # under <tenant>.<zone>, never at the apex.
        rname="${rname%.}"
        if [[ "$rname" == "$zone" ]]; then
            log_warn "mail_upstream_setup_domain: unexpected apex record for ${rtype} on zone '${zone}' — skipping"
            continue
        fi
        if [[ "$rname" != *".${zone}" ]]; then
            log_warn "mail_upstream_setup_domain: record ${rtype} name '${rname}' not under BEBOP_DNS_ZONE='${zone}' — skipping"
            continue
        fi
        label="${rname%.${zone}}"
        dns_provider_dns_record_create "$label" TXT "$rval" 300 >/dev/null \
            || { log_warn "mail_upstream_setup_domain: dns_provider_dns_record_create failed for ${rtype} (${label}.${zone})"; return 1; }
    done
    dns_provider_dns_zone_refresh

    # 4. Kick off Scaleway's DNS re-verification. Records are visible on
    # our zone by now; a first /check + short poll usually flips the
    # status to "checked" in under 30 s. If it doesn't (e.g. Scaleway
    # temporarily can't resolve, or the resolver cache lags), we don't
    # block or fail — the caller stores upstream_domain_id, and the
    # retry-upstream sweep polls again every 15 min via
    # mail_upstream_recheck until the domain validates.
    mail_upstream_recheck "$domain_id" "$full_domain" || true

    printf '%s\n' "$domain_id"
}

# mail_upstream_recheck <domain_id> <full_domain>
#
# Fires POST /domains/<id>/check and polls GET /domains/<id> briefly for
# status="checked". Cheap enough to run on every retry-upstream tick
# against already-registered-but-not-yet-validated tenants.
#
# Returns 0 iff the domain is validated by the end of the poll window;
# non-zero otherwise (caller keeps polling on subsequent ticks). Never
# fails on transport errors — logs and returns non-zero.
mail_upstream_recheck() {
    local domain_id="$1" full_domain="$2"
    [[ -z "$domain_id" ]] && { log_error "mail_upstream_recheck: domain_id required"; return 2; }
    if ! scaleway_tem_domain_check "$domain_id" >/dev/null 2>&1; then
        log_warn "mail_upstream_recheck: /check request failed for id=${domain_id}"
        return 1
    fi
    local status attempt=0
    while (( attempt < 6 )); do
        status=$(scaleway_tem_domain_status "$domain_id" 2>/dev/null || true)
        if [[ "$status" == "checked" ]]; then
            log_info "mail_upstream_recheck: domain '${full_domain:-id=$domain_id}' validated (status=checked)"
            return 0
        fi
        sleep 5
        (( ++attempt ))
    done
    log_warn "mail_upstream_recheck: domain '${full_domain:-id=$domain_id}' still status='${status:-<unknown>}' after 30s — will retry on next tick"
    return 1
}

# mail_upstream_teardown_domain <tenant_subdomain_label> <full_domain>
#
# Reverse of mail_upstream_setup_domain: drop the provider-side domain
# and remove the DNS records we posted. Refuses to skip silently when
# upstream isn't reachable — a silent skip leaves an orphan on the
# provider side that consumes quota (Scaleway TEM Essential = 5 domains
# hard cap) until an operator notices and cleans it up manually. So we
# die() instead: the caller (remove-tenant.sh) surfaces the failure and
# the operator either fixes secrets.env then retries, or knowingly opts
# out of the strict path.
mail_upstream_teardown_domain() {
    local subdomain_label="$1" full_domain="$2"
    [[ -z "$subdomain_label" || -z "$full_domain" ]] \
        && { log_warn "mail_upstream_teardown_domain: skipping (empty args)"; return 0; }
    local zone="${BEBOP_DNS_ZONE:-}"

    if ! mail_upstream_is_configured; then
        die "mail_upstream_teardown_domain: upstream provider not configured (SCALEWAY_TEM_API_KEY / SCALEWAY_TEM_PROJECT_ID missing in ${SECRETS_FILE:-/etc/be-BOP-tooling/secrets.env}). Refusing to proceed — a silent skip here would leave '${full_domain}' as an orphan on Scaleway (quota-consuming). Fix secrets.env and retry."
    fi

    # Fetch the record labels from Scaleway BEFORE deleting the upstream
    # domain — DKIM's selector is the project UUID (unknown to us
    # otherwise) so hardcoding "scw._domainkey" would leave orphan
    # records in the zone. If upstream is unreachable / missing, fall
    # back to a best-effort SPF + DMARC cleanup on predictable labels
    # (the DKIM leaves behind an orphan we can't identify blindly).
    local -a labels_to_delete=()
    local domain_id=""
    domain_id=$(scaleway_tem_domain_find "$full_domain" 2>/dev/null || true)
    if [[ -n "$domain_id" && -n "$zone" ]]; then
        local dom_json rname rtype
        if dom_json=$(scaleway_tem_domain_get "$domain_id" 2>/dev/null); then
            for rtype in spf dkim dmarc; do
                rname=$(printf '%s' "$dom_json" | jq -r ".records.${rtype}.name // empty")
                rname="${rname%.}"
                [[ -z "$rname" || "$rname" != *".${zone}" ]] && continue
                labels_to_delete+=("${rname%.${zone}}")
            done
        fi
    fi
    if (( ${#labels_to_delete[@]} == 0 )); then
        log_warn "mail_upstream_teardown_domain: no upstream record map available for '${full_domain}' — best-effort SPF+DMARC cleanup only (DKIM record, if any, must be pruned manually)"
        labels_to_delete=("$subdomain_label" "_dmarc.${subdomain_label}")
    fi

    if [[ -n "$domain_id" ]]; then
        scaleway_tem_domain_delete "$domain_id" \
            || log_warn "mail_upstream_teardown_domain: provider delete failed for '${full_domain}'"
    fi
    local host id
    for host in "${labels_to_delete[@]}"; do
        id=$(dns_provider_dns_record_find "$host" TXT 2>/dev/null || true)
        [[ -n "$id" ]] && dns_provider_dns_record_delete "$id" 2>/dev/null || true
    done
}

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# migrate-tenant.sh — change a tenant's public domain in one of four ways:
#     internal → internal  (subdomain rename within OVH_DNS_ZONE)
#     internal → external  (switch to an operator-owned FQDN)
#     external → internal  (fall back to a subdomain in OVH_DNS_ZONE)
#     external → external  (rename the operator-owned FQDN)
#
# Under the hood the migration re-uses add-tenant.sh's "reapply" path:
#   1. Pre-flight (registry status, target availability, DNS pointers if ext).
#   2. Delete the tenant's existing Let's Encrypt cert(s) so the reapply
#      forces a fresh issuance (cert names are ID-based; certbot's cache
#      would otherwise skip re-issuance and the new SAN would never land).
#   3. Update /var/lib/be-BOP/tenants.tsv's `domain` field to the new value.
#      add-tenant.sh reapply reads domain from the registry and auto-detects
#      internal vs. external mode from it.
#   4. Fork `add-tenant.sh <tenant_id>` — reapply regenerates config.env,
#      cert, nginx vhost, and restarts bebop@<tenant> in one pass.
#   5. Post-cleanup: delete the OLD DNS A record(s) when the old mode was
#      internal (never touches operator-managed external DNS).
#   6. notify_success via lib/notify.sh.
#
# Data (Mongo, Garage bucket, phoenixd state) is NOT touched — only the
# public entrypoint moves. The tenant_id itself never changes; only the
# domain field.
#
# Not transactional: if step 4 fails after step 3, the tenant is in a
# broken state (registry says new domain, cert/nginx/config say nothing).
# Manual recovery: revert registry.domain and rerun `add-tenant.sh <tid>`.

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="migrate-tenant"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "migrate-tenant: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/ovh.sh
source "$BEBOP_TOOLING_LIB_DIR/ovh.sh"
# shellcheck source=lib/dns.sh
source "$BEBOP_TOOLING_LIB_DIR/dns.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"

: "${SECRETS_FILE:=/etc/be-BOP-tooling/secrets.env}"

TENANT_ID=""
TO_SUBDOMAIN=""
TO_EXTERNAL=""
ADMIN_EMAIL=""
NON_INTERACTIVE="false"
IKNOW="false"

usage() {
    cat <<EOF
Usage:
  migrate-tenant.sh <tenant_id> --to-subdomain <slug>
  migrate-tenant.sh <tenant_id> --to-external <fqdn>

Options:
  --admin-email <email>    LE account email for the new cert issuance.
                           Default: reuse the existing tenant's admin email
                           (looked up from the current cert if possible; else
                           the operator SMTP_FROM as last resort).
  --non-interactive        Skip the yes/no confirmation prompt.
                           Requires --i-know-what-im-doing.
  --i-know-what-im-doing   Acknowledge that this operation deletes the old LE
                           cert and DNS records with no automated rollback.
  -h, --help               This message.

Notes:
  * The tenant_id never changes; only the public domain does.
  * Data (Mongo, Garage, phoenixd) is preserved.
  * Cert re-issuance may take 30-90s (DNS-01 propagation).
  * External mode requires IPv6 on the VDS.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --to-subdomain)          TO_SUBDOMAIN="$2"; shift 2 ;;
        --to-external)           TO_EXTERNAL="$2";  shift 2 ;;
        --admin-email)           ADMIN_EMAIL="$2";  shift 2 ;;
        --non-interactive)       NON_INTERACTIVE="true"; shift ;;
        --i-know-what-im-doing)  IKNOW="true"; shift ;;
        -h|--help)               usage; exit 0 ;;
        --*)                     usage; die "unknown flag: $1" ;;
        *)
            if [[ -z "$TENANT_ID" ]]; then
                TENANT_ID="$1"; shift
            else
                usage; die "unexpected positional arg: $1"
            fi
            ;;
    esac
done

[[ -z "$TENANT_ID" ]]                     && { usage; die "tenant_id is required"; }
[[ -z "$TO_SUBDOMAIN" && -z "$TO_EXTERNAL" ]] && { usage; die "--to-subdomain OR --to-external is required"; }
[[ -n "$TO_SUBDOMAIN" && -n "$TO_EXTERNAL" ]] && { usage; die "--to-subdomain and --to-external are mutually exclusive"; }
if [[ "$NON_INTERACTIVE" == "true" && "$IKNOW" != "true" ]]; then
    die "--non-interactive requires --i-know-what-im-doing (this op is not fully reversible)"
fi

[[ -f "$SECRETS_FILE" ]] || die "secrets file not found: $SECRETS_FILE"
# shellcheck disable=SC1090
source "$SECRETS_FILE"
[[ -n "${OVH_DNS_ZONE:-}" ]] || die "OVH_DNS_ZONE not set in $SECRETS_FILE"

require_privileges

registry_init
registry_lock
# Registry unlock happens BEFORE we fork add-tenant.sh (it takes its own
# lock). We use a manual call rather than an EXIT trap to keep the ordering
# explicit — the fork must be lock-free.

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
STATUS=$(registry_get_status "$TENANT_ID")
if [[ "$STATUS" != "active" ]]; then
    registry_unlock
    die "tenant '$TENANT_ID' status is '$STATUS' — only 'active' tenants can be migrated"
fi

CURRENT_DOMAIN=$(registry_get_field "$TENANT_ID" domain)
if [[ -z "$CURRENT_DOMAIN" ]]; then
    registry_unlock
    die "tenant '$TENANT_ID' has empty domain in registry (should not happen for status=active)"
fi

# Determine current mode from the registry-recorded domain.
if [[ "$CURRENT_DOMAIN" == "${TENANT_ID}.${OVH_DNS_ZONE}" ]]; then
    CURRENT_MODE="internal"
    OLD_SUB="$TENANT_ID"
else
    CURRENT_MODE="external"
    OLD_SUB=""
fi

# Determine new mode + new domain from flags.
if [[ -n "$TO_SUBDOMAIN" ]]; then
    NEW_MODE="internal"
    # Same slug rules as add-tenant.sh — kept in sync manually. A future
    # refactor should extract them to lib/slug.sh so both scripts agree
    # without duplication.
    if [[ ! "$TO_SUBDOMAIN" =~ ^[a-z0-9][a-z0-9-]*$ ]] || (( ${#TO_SUBDOMAIN} > 32 )); then
        registry_unlock
        die "invalid --to-subdomain '$TO_SUBDOMAIN' (must match [a-z0-9][a-z0-9-]*, ≤32 chars)"
    fi
    NEW_DOMAIN="${TO_SUBDOMAIN}.${OVH_DNS_ZONE}"
    NEW_SUB="$TO_SUBDOMAIN"
else
    NEW_MODE="external"
    if [[ ! "$TO_EXTERNAL" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
        registry_unlock
        die "invalid --to-external '$TO_EXTERNAL' (expected an FQDN like bebop.example.com)"
    fi
    if [[ "$TO_EXTERNAL" == *".${OVH_DNS_ZONE}" ]]; then
        registry_unlock
        die "--to-external '$TO_EXTERNAL' is inside OVH_DNS_ZONE='$OVH_DNS_ZONE'; use --to-subdomain instead"
    fi
    NEW_DOMAIN="$TO_EXTERNAL"
    NEW_SUB=""
fi

if [[ "$NEW_DOMAIN" == "$CURRENT_DOMAIN" ]]; then
    registry_unlock
    log_info "migrate: no-op — new domain equals current ($CURRENT_DOMAIN)"
    exit 0
fi

# Collision check for internal target: no OTHER tenant currently uses the
# target subdomain. The registry's domain column is the source of truth.
if [[ "$NEW_MODE" == "internal" ]]; then
    other=$(awk -F'\t' -v d="$NEW_DOMAIN" -v t="$TENANT_ID" \
        'NR>1 && $2==d && $1!=t {print $1; exit}' "$REGISTRY_PATH" || true)
    if [[ -n "$other" ]]; then
        registry_unlock
        die "domain '$NEW_DOMAIN' is already used by tenant '$other'"
    fi
fi

# Host IP detection (same helpers add-tenant.sh uses).
if [[ -n "${BEBOP_HOST_IP:-}" ]]; then
    HOST_IP="$BEBOP_HOST_IP"
else
    HOST_IP=$(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)
fi
[[ "$HOST_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { registry_unlock; die "could not detect host public IPv4 — set BEBOP_HOST_IP"; }

HOST_IPV6=""
if [[ "$NEW_MODE" == "external" ]]; then
    if [[ -n "${BEBOP_HOST_IPV6:-}" ]]; then
        HOST_IPV6="$BEBOP_HOST_IPV6"
    else
        HOST_IPV6=$(curl -sS --max-time 10 https://api6.ipify.org 2>/dev/null || true)
    fi
    if [[ ! "$HOST_IPV6" =~ ^[0-9a-fA-F:]+$ ]]; then
        registry_unlock
        die "external target requires IPv6 on the VDS — set BEBOP_HOST_IPV6 in $SECRETS_FILE"
    fi
    # DNS pre-flight: the operator must have already pointed A + AAAA at us.
    # Same all-or-nothing contract as add-tenant.sh --external-domain.
    dns_check_external_fqdn "$NEW_DOMAIN" "$HOST_IP" "$HOST_IPV6"
fi

log_info "migrate: '$TENANT_ID' from $CURRENT_DOMAIN ($CURRENT_MODE) → $NEW_DOMAIN ($NEW_MODE)"

# Confirmation.
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    cat >&2 <<EOF

--- migrate-tenant confirmation --------------------------------------------
  Tenant:       $TENANT_ID
  From:         $CURRENT_DOMAIN  ($CURRENT_MODE)
  To:           $NEW_DOMAIN      ($NEW_MODE)

This will:
  * delete the tenant's current Let's Encrypt cert(s)
  * update the DNS records in zone '$OVH_DNS_ZONE' (internal-mode side only)
  * regenerate config.env, nginx vhost, and issue a new cert
  * restart bebop@$TENANT_ID (~10-20s downtime for the buyer)
Rollback is manual if a step fails after the registry has been updated.

----------------------------------------------------------------------------
EOF
    read -rp "Type the tenant_id to confirm: " confirm
    if [[ "$confirm" != "$TENANT_ID" ]]; then
        registry_unlock
        die "confirmation mismatch — aborting"
    fi
fi

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

# 1. Delete existing cert(s). Cert names are ID-based (see add-tenant.sh:
#    CERT_NAME="bebop-${TENANT_ID}", S3_CERT_NAME="bebop-${TENANT_ID}-s3"
#    only in external+localS3 mode). `|| true` on both — certbot delete on
#    a non-existent cert exits non-zero.
CERT_NAME="bebop-${TENANT_ID}"
S3_CERT_NAME="bebop-${TENANT_ID}-s3"
log_info "migrate: deleting cert '$CERT_NAME' (if present)..."
run_privileged certbot delete --non-interactive --cert-name "$CERT_NAME" 2>/dev/null || true
log_info "migrate: deleting cert '$S3_CERT_NAME' (if present)..."
run_privileged certbot delete --non-interactive --cert-name "$S3_CERT_NAME" 2>/dev/null || true

# 2. If new mode is internal, publish new A records BEFORE the reapply. This
#    is not strictly required for DNS-01 (LE only checks _acme-challenge)
#    but makes the tenant reachable the moment nginx reloads.
if [[ "$NEW_MODE" == "internal" ]]; then
    log_info "migrate: creating DNS A '$NEW_SUB' → $HOST_IP..."
    ovh_dns_record_create "$NEW_SUB" A "$HOST_IP" >/dev/null
    # s3.<sub> is always internal even when the tenant's main is external;
    # add-tenant.sh always renders s3 under OVH_DNS_ZONE. Same rule here.
    log_info "migrate: creating DNS A 's3.$NEW_SUB' → $HOST_IP..."
    ovh_dns_record_create "s3.$NEW_SUB" A "$HOST_IP" >/dev/null
    ovh_dns_zone_refresh
fi

# 3. Point the registry at the new domain. add-tenant.sh reapply reads
#    this to derive internal/external mode.
log_info "migrate: updating registry.domain: $CURRENT_DOMAIN → $NEW_DOMAIN"
registry_set_field "$TENANT_ID" domain "$NEW_DOMAIN"

# 4. Release the registry lock BEFORE forking add-tenant.sh (it grabs its own).
registry_unlock

# 5. Reapply — regenerates config, cert, nginx, restarts bebop.
#    We forward the admin_email if provided; otherwise add-tenant.sh keeps
#    what's already in the tenant's config.env.
addtenant_args=("$TENANT_ID" --non-interactive)
[[ -n "$ADMIN_EMAIL" ]] && addtenant_args+=(--admin-email "$ADMIN_EMAIL")

log_info "migrate: forking add-tenant.sh (reapply) with new domain..."
if ! "$SCRIPT_DIR/add-tenant.sh" "${addtenant_args[@]}"; then
    log_error "migrate: add-tenant.sh reapply FAILED — tenant is in an inconsistent state"
    log_error "  Recovery: manually restore registry.domain to '$CURRENT_DOMAIN' and rerun add-tenant.sh $TENANT_ID"
    notify_failure \
        "[be-BOP tooling] migrate-tenant $TENANT_ID FAILED" \
        "Reapply after registry update failed. Recovery: revert registry.domain to '$CURRENT_DOMAIN' and rerun add-tenant.sh."
    exit 1
fi

# 6. Post-cleanup: delete the OLD internal DNS A record(s) once we're sure
#    the tenant serves under the new domain. Nothing to do when the old mode
#    was external (operator manages that DNS).
if [[ "$CURRENT_MODE" == "internal" && "$OLD_SUB" != "${NEW_SUB:-}" ]]; then
    # Re-acquire lock briefly for the DNS cleanup log line consistency.
    registry_lock
    log_info "migrate: cleaning up old DNS A '$OLD_SUB'..."
    old_id=$(ovh_dns_record_find "$OLD_SUB" A 2>/dev/null || true)
    if [[ -n "$old_id" ]]; then
        ovh_dns_record_delete "$old_id" || log_warn "migrate: old A delete failed for id=$old_id"
    fi
    log_info "migrate: cleaning up old DNS A 's3.$OLD_SUB'..."
    old_s3_id=$(ovh_dns_record_find "s3.$OLD_SUB" A 2>/dev/null || true)
    if [[ -n "$old_s3_id" ]]; then
        ovh_dns_record_delete "$old_s3_id" || log_warn "migrate: old s3 A delete failed for id=$old_s3_id"
    fi
    ovh_dns_zone_refresh
    registry_unlock
fi

notify_success \
    "[be-BOP tooling] migrate-tenant $TENANT_ID OK" \
    "Tenant $TENANT_ID public domain migrated:
  from: $CURRENT_DOMAIN ($CURRENT_MODE)
  to:   $NEW_DOMAIN ($NEW_MODE)"

log_info "migrate: '$TENANT_ID' now serving at $NEW_DOMAIN"

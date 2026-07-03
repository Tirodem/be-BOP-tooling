#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# add-tenant.sh — onboard a new be-BOP tenant on a host already prepared by
# host-bootstrap.sh. Transactional with automatic rollback on failure.
#
# Behaviour by tenant status (looked up in /var/lib/be-BOP/tenants.tsv):
#   absent       → fresh creation: 14 phases (DNS, Mongo, Garage, release,
#                  phoenixd, config, cert, nginx, bebop, healthcheck, …);
#                  any failure rolls back every step taken so far
#   active       → idempotent re-apply: rewrites config + vhost, no data
#                  changes, no rollback needed
#   soft-deleted → refused unless --reactivate is given
#   archived     → always refused (data has been off-loaded; pick a new id)

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="add-tenant"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate libs and templates: source-tree layout when invoked from a checkout,
# system layout once installed under /usr/local/share/be-BOP-tooling.
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
    BEBOP_TOOLING_TEMPLATE_DIR="$SCRIPT_DIR/templates"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
    BEBOP_TOOLING_TEMPLATE_DIR=/usr/local/share/be-BOP-tooling/templates
else
    echo "add-tenant: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/transaction.sh
source "$BEBOP_TOOLING_LIB_DIR/transaction.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/ovh.sh
source "$BEBOP_TOOLING_LIB_DIR/ovh.sh"
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"
# shellcheck source=lib/garage.sh
source "$BEBOP_TOOLING_LIB_DIR/garage.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/uptime-kuma.sh
source "$BEBOP_TOOLING_LIB_DIR/uptime-kuma.sh"
# shellcheck source=lib/healthcheck.sh
source "$BEBOP_TOOLING_LIB_DIR/healthcheck.sh"
# shellcheck source=lib/release.sh
source "$BEBOP_TOOLING_LIB_DIR/release.sh"
# shellcheck source=lib/dns.sh
source "$BEBOP_TOOLING_LIB_DIR/dns.sh"
# shellcheck source=lib/phoenixd.sh
source "$BEBOP_TOOLING_LIB_DIR/phoenixd.sh"

# === EXIT trap ==========================================================
# Defined early so it's in scope from any failure point — including the
# CLI-validation block below and any die() called from phase_*. ERR alone
# wouldn't catch die() (which exits directly; ERR only fires on simple-
# command non-zero exits, not on `exit`). The trap is armed lower, after
# BEBOP_TOOLING_TENANT_ID is set, so log lines in the notification are
# correctly tagged. NOTIFIED flag prevents duplicates (happy paths set it
# to true after notify_success).
NOTIFIED=false
on_script_exit() {
    local rc=$?
    # On the happy path the body of run_* sets NOTIFIED=true after sending
    # the success notification, so we skip the failure path here.
    if [[ "$NOTIFIED" != "true" ]] && (( rc != 0 )); then
        NOTIFIED=true
        log_error "add-tenant: failure (exit code ${rc}); initiating rollback"
        txn_rollback 2>/dev/null || true
        local body
        body=$(printf 'Tenant: %s\nDecision path: %s\nFailure exit code: %d\nUndo steps attempted: %d\n\nSee journalctl -t %s --since "1 hour ago" for the full log.\n' \
            "${TENANT_ID:-(unset)}" "${DECISION_PATH:-fresh}" "$rc" \
            "$(txn_size 2>/dev/null || echo 0)" "${BEBOP_TOOLING_SYSLOG_IDENT:-bebop-tooling-add-tenant}")
        notify_failure \
            "[be-BOP tooling] add-tenant ${TENANT_ID:-(unset)} FAILED" \
            "$body" || true
    fi
    # ALWAYS release the registry lock, on success or failure. registry_unlock
    # is a no-op if no lock is held (returns 0 immediately) so it's safe to
    # call even when the trap fires before registry_lock has run. This used
    # to be a separate `trap "registry_unlock" EXIT` inside main(), but
    # bash keeps only ONE EXIT handler (last `trap … EXIT` wins) — combining
    # both responsibilities here is what prevents the lock-release / failure-
    # notification regression seen in a127560.
    registry_unlock 2>/dev/null || true
}

# === Constants ==========================================================
readonly TENANT_REGEX='^[a-z0-9][a-z0-9-]*$'
readonly TENANT_MAX_LEN=32
# Subdomains used by host-level infrastructure (Netdata UI, future Kuma
# / Grafana exposure, the s3.* pattern for tenant Garage endpoints, and
# common conventional names). A tenant_id matching any of these would
# collide with an existing or planned vhost/cert/DNS record.
readonly RESERVED_TENANT_IDS=(
    netdata kuma grafana monitoring metrics status
    s3 garage www admin api mail mx ns dns
    root system bebop phoenixd mongod
    dashboard panel saas ops
    deploy
)
# Hard cap on the number of *active* tenants per host. Overridable via the
# BEBOP_TENANT_CAP env var (or secrets.env). Lifted via the `absent` →
# `fresh` path only — re-applies, reactivations, and removals are exempt.
: "${BEBOP_TENANT_CAP:=16}"
readonly DEFAULT_BUCKET_QUOTA="20GiB"
readonly TEMPLATE_REVISION="2026062101"
readonly HEALTHCHECK_RETRIES=15
readonly HEALTHCHECK_INTERVAL=2
readonly PHOENIXD_PASSWORD_RETRIES=20
readonly PHOENIXD_PASSWORD_INTERVAL=2

# === CLI ================================================================
SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
TENANT_ID=""
ADMIN_EMAIL=""
EXTERNAL_DOMAIN=""    # set by --external-domain <fqdn>; empty = internal tenant
NO_LOCAL_S3=false     # set by --no-local-s3; true = skip Garage/S3 plumbing
ENABLE_PHOENIXD=true
BEBOP_VERSION="latest"
REACTIVATE=false
DRY_RUN=false
RUN_NON_INTERACTIVE=false
VERBOSE=false
# Runtime-config overrides: stored as "<lock>:<key>=<value>" strings, applied
# against the tenant's mongod runtimeConfig collection right before
# bebop@<tenant> is (re)started. See parse_runtime_config_flag below.
RUNTIME_CONFIG_OVERRIDES=()

# Validates --runtime-config / --runtime-config-locked argument and appends to
# RUNTIME_CONFIG_OVERRIDES. <lock> is "true" or "false".
parse_runtime_config_flag() {
    local lock="$1" arg="$2"
    if [[ ! "$arg" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
        die "invalid runtime-config '${arg}': expected KEY=VALUE (KEY must match [a-zA-Z_][a-zA-Z0-9_]*)"
    fi
    RUNTIME_CONFIG_OVERRIDES+=("${lock}:${arg}")
}

usage() {
    cat <<EOF
add-tenant.sh — onboard a new be-BOP tenant.

Usage:
  add-tenant.sh <tenant_id> --admin-email <email> [options]

Required:
  <tenant_id>             slug, [a-z0-9][a-z0-9-]*, max ${TENANT_MAX_LEN} chars
  --admin-email <email>   merchant contact — used as the Let's Encrypt
                          account email AND for be-BOP tooling alerts

Optional:
  --no-phoenixd           skip the per-tenant phoenixd daemon (default: enabled)
  --bebop-version <tag>   GitHub release tag of be-BOP, or "latest" (default)
  --external-domain <fqdn>
                          deploy under <fqdn> instead of the default
                          <tenant_id>.<OVH_DNS_ZONE>. The operator MUST
                          configure both A and AAAA records on their DNS
                          provider pointing to this VDS before running.
                          The S3 endpoint stays internal at
                          s3.<tenant_id>.<OVH_DNS_ZONE>. The main cert is
                          issued via HTTP-01 (separate from the S3 DNS-01
                          cert). Requires public IPv6 on the VDS.
  --no-local-s3           do NOT provision a local Garage bucket + key for
                          this tenant. be-BOP starts with empty S3 env vars
                          so the merchant configures their own external S3
                          via the be-BOP UI. Implies: no s3.<tenant>.<zone>
                          DNS record, no S3 cert, no S3 nginx server block.
  --reactivate            restore a soft-deleted tenant (preserves data)
  --runtime-config KEY=VALUE
                          upsert {_id:KEY, data:VALUE} into the tenant's
                          runtimeConfig collection just before bebop starts.
                          Repeatable. Clears any existing lock on KEY.
                          Example: --runtime-config websiteTitle="ACME Shop"
  --runtime-config-locked KEY=VALUE
                          same as --runtime-config but also sets lock:true,
                          marking the entry read-only in the be-BOP UI.
                          Repeatable. Example: --runtime-config-locked vatCountry=FR
  --secrets-file <path>   override default ${SECRETS_FILE}
  --non-interactive       no prompts; fail if input would be required
  --dry-run               print actions without executing
  --verbose               verbose logging
  -h, --help

Status semantics (looked up in /var/lib/be-BOP/tenants.tsv):
  absent       → fresh creation (14 phases, full rollback on failure)
  active       → idempotent: re-applies config + vhost, restarts on drift
  soft-deleted → refused unless --reactivate
  archived     → always refused (pick a different tenant_id)
EOF
}

# Parse arguments — first non-flag is tenant_id.
while (( $# )); do
    case "$1" in
        --admin-email)     ADMIN_EMAIL="$2"; shift 2 ;;
        --phoenixd)        ENABLE_PHOENIXD=true; shift ;;
        --no-phoenixd)     ENABLE_PHOENIXD=false; shift ;;
        --bebop-version)   BEBOP_VERSION="$2"; shift 2 ;;
        --external-domain) EXTERNAL_DOMAIN="$2"; shift 2 ;;
        --no-local-s3)     NO_LOCAL_S3=true; shift ;;
        --reactivate)      REACTIVATE=true; shift ;;
        --runtime-config)        parse_runtime_config_flag "false" "$2"; shift 2 ;;
        --runtime-config-locked) parse_runtime_config_flag "true"  "$2"; shift 2 ;;
        --secrets-file)    SECRETS_FILE="$2"; shift 2 ;;
        --non-interactive) RUN_NON_INTERACTIVE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --verbose)         VERBOSE=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)
            if [[ -n "$TENANT_ID" ]]; then
                die "multiple tenant ids on command line: '${TENANT_ID}' and '$1'"
            fi
            TENANT_ID="$1"; shift
            ;;
    esac
done

# Required arg validation.
if [[ -z "$TENANT_ID" ]]; then
    usage; die "tenant_id is required"
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
    die "--admin-email is required"
fi
if [[ ! "$TENANT_ID" =~ $TENANT_REGEX ]]; then
    die "invalid tenant_id '${TENANT_ID}' (must match ${TENANT_REGEX})"
fi
if (( ${#TENANT_ID} > TENANT_MAX_LEN )); then
    die "tenant_id too long (max ${TENANT_MAX_LEN}): '${TENANT_ID}'"
fi
for _reserved in "${RESERVED_TENANT_IDS[@]}"; do
    if [[ "$TENANT_ID" == "$_reserved" ]]; then
        die "tenant_id '${TENANT_ID}' is reserved (collides with host-level infrastructure subdomains; see RESERVED_TENANT_IDS in add-tenant.sh)"
    fi
done
unset _reserved

# --external-domain: validate FQDN syntax + refuse a domain that's actually
# under OVH_DNS_ZONE (= would be an internal tenant misusing the flag).
if [[ -n "$EXTERNAL_DOMAIN" ]]; then
    if [[ ! "$EXTERNAL_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
        die "invalid --external-domain '${EXTERNAL_DOMAIN}' (expected an FQDN like bebop.example.com)"
    fi
fi

is_external_mode() { [[ -n "$EXTERNAL_DOMAIN" ]]; }
has_local_s3()    { [[ "$NO_LOCAL_S3" != "true" ]]; }

# Tag log lines with the tenant id from now on.
BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_TENANT_ID BEBOP_TOOLING_SYSLOG_IDENT
export RUN_NON_INTERACTIVE VERBOSE DRY_RUN

trap 'on_script_exit' EXIT

# === Globals (set during phases) ========================================
DOMAIN=""              # <tenant>.<zone> for internal; --external-domain value otherwise
S3_DOMAIN=""           # s3.<tenant>.<zone>  (always internal — even for --external-domain tenants)
ZONE=""                # <zone> from secrets.env
HOST_IP=""
HOST_IPV6=""           # only populated in external-domain mode (used for DNS pre-flight)
BEBOP_PORT=""
PHOENIXD_PORT=""
MONGO_PORT=""
GARAGE_BUCKET=""
GARAGE_KEY_NAME=""
GARAGE_KEY_ID=""
GARAGE_KEY_SECRET=""
MONGO_DB_NAME=""
MONGO_URL=""
PHOENIXD_HTTP_PASSWORD=""
PHOENIXD_SEED_HEX=""
DNS_RECORD_BEBOP_ID=""
DNS_RECORD_S3_ID=""
RESOLVED_VERSION=""
CERT_NAME=""           # main cert: covers DOMAIN
S3_CERT_NAME=""        # internal: == CERT_NAME (one SAN cert); external: distinct, DNS-01 only for S3

# === Helpers ============================================================
detect_host_ip() {
    if [[ -n "${BEBOP_HOST_IP:-}" ]]; then
        HOST_IP="$BEBOP_HOST_IP"
    else
        HOST_IP=$(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$HOST_IP" || ! "$HOST_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        die "could not detect host public IP — set BEBOP_HOST_IP env var explicitly"
    fi
    log_info "host public IPv4: ${HOST_IP}"
}

# Required only for --external-domain mode: the external FQDN's AAAA must
# match BEBOP_HOST_IPV6. We expose this even on IPv4-only operations to keep
# the failure mode clear ("VDS has no IPv6 → external mode not usable").
detect_host_ipv6() {
    if [[ -n "${BEBOP_HOST_IPV6:-}" ]]; then
        HOST_IPV6="$BEBOP_HOST_IPV6"
    else
        HOST_IPV6=$(curl -sS --max-time 10 https://api6.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$HOST_IPV6" || ! "$HOST_IPV6" =~ ^[0-9a-fA-F:]+$ ]]; then
        die "could not detect host public IPv6 — external-domain mode requires IPv6 on the VDS. Either set BEBOP_HOST_IPV6 in ${SECRETS_FILE} OR drop --external-domain."
    fi
    log_info "host public IPv6: ${HOST_IPV6}"
}

# Generate a 32-char URL-safe random password.
gen_password() {
    openssl rand -base64 48 | tr -d '/+=\n' | head -c 32
}

# render_template <template_path> <key1> <val1> [<key2> <val2> ...]
# Substitutes @keyN@ tokens in the template stream and outputs to stdout.
render_template() {
    local tmpl="$1"; shift
    local sed_args=()
    while (( $# >= 2 )); do
        local key="$1" val="$2"
        # Escape sed replacement metacharacters: \ first, then | (delimiter), then &
        val="${val//\\/\\\\}"
        val="${val//|/\\|}"
        val="${val//&/\\&}"
        sed_args+=("-e" "s|@${key}@|${val}|g")
        shift 2
    done
    sed "${sed_args[@]}" "$tmpl"
}

# === Phase implementations ==============================================

# Phase 1: status decision and registry lock
phase_status_decision() {
    local status
    status=$(registry_get_status "$TENANT_ID")
    log_info "phase 1: tenant '${TENANT_ID}' status = ${status}"
    case "$status" in
        absent)
            # Enforce the host-wide active-tenant cap on fresh creations only.
            # Re-applies / reactivations of existing tenants are exempt — the
            # tenant already counts, so capping them is meaningless and would
            # block recovery.
            local active_count
            active_count=$(registry_count_by_status active)
            if (( active_count >= BEBOP_TENANT_CAP )); then
                die "tenant cap reached: ${active_count}/${BEBOP_TENANT_CAP} active tenants on this host. Raise BEBOP_TENANT_CAP or remove an idle tenant first (remove-tenant.sh <id> [--archive|--purge])."
            fi
            return 0
            ;;
        active)
            log_info "tenant '${TENANT_ID}' is already active — running in idempotent re-apply mode"
            DECISION_PATH="reapply"
            ;;
        soft-deleted)
            if [[ "$REACTIVATE" != "true" ]]; then
                die "tenant '${TENANT_ID}' is soft-deleted; pass --reactivate to restore, or 'remove-tenant.sh ${TENANT_ID} --purge' first to start fresh"
            fi
            log_info "reactivating soft-deleted tenant '${TENANT_ID}' (data preserved)"
            DECISION_PATH="reactivate"
            ;;
        archived)
            die "tenant '${TENANT_ID}' is archived (data uploaded to SFTP) — pick a different tenant_id"
            ;;
        *)
            die "unexpected tenant status '${status}' in registry"
            ;;
    esac
}

# Phase 2: ports, domain names, identifier derivation
phase_derive_identifiers() {
    log_info "phase 2: deriving identifiers..."
    ZONE="${OVH_DNS_ZONE:?OVH_DNS_ZONE missing in secrets.env}"

    # On reapply / reactivate, recover the external-domain mode from the
    # registry if the caller didn't pass --external-domain. Saves the
    # operator from having to remember the flag for routine re-applies.
    if [[ "${DECISION_PATH:-fresh}" != "fresh" && -z "$EXTERNAL_DOMAIN" ]]; then
        local existing_domain
        existing_domain=$(registry_get_field "$TENANT_ID" domain)
        if [[ -n "$existing_domain" && "$existing_domain" != "${TENANT_ID}.${ZONE}" ]]; then
            EXTERNAL_DOMAIN="$existing_domain"
            log_info "detected external-domain tenant from registry: ${EXTERNAL_DOMAIN}"
        fi
    fi
    # Same for --no-local-s3: derive from the registry on reapply/reactivate
    # by checking if garage_bucket is empty (= was provisioned without a
    # local Garage bucket). Operator doesn't have to remember the flag.
    if [[ "${DECISION_PATH:-fresh}" != "fresh" && "$NO_LOCAL_S3" != "true" ]]; then
        local existing_bucket
        existing_bucket=$(registry_get_field "$TENANT_ID" garage_bucket)
        if [[ -z "$existing_bucket" ]]; then
            NO_LOCAL_S3=true
            log_info "detected --no-local-s3 tenant from registry (empty garage_bucket)"
        fi
    fi

    if is_external_mode; then
        # External public FQDN; reject if it happens to land back inside our zone.
        DOMAIN="$EXTERNAL_DOMAIN"
        if [[ "$DOMAIN" == *".${ZONE}" ]]; then
            die "--external-domain '${DOMAIN}' is under OVH_DNS_ZONE='${ZONE}'; drop the flag to use the standard internal path"
        fi
        CERT_NAME="bebop-${TENANT_ID}"
    else
        DOMAIN="${TENANT_ID}.${ZONE}"
        CERT_NAME="bebop-${TENANT_ID}"
    fi
    # S3 plumbing: only when has_local_s3. Otherwise S3_* stays empty and
    # nothing s3-related (cert, vhost block, DNS, Garage) is created.
    if has_local_s3; then
        S3_DOMAIN="s3.${TENANT_ID}.${ZONE}"
        GARAGE_BUCKET="bebop-${TENANT_ID}"
        GARAGE_KEY_NAME="bebop-${TENANT_ID}-key"
        if is_external_mode; then
            # External main (HTTP-01) + internal S3 (DNS-01) = 2 distinct certs.
            S3_CERT_NAME="bebop-${TENANT_ID}-s3"
        else
            # Single SAN cert covers main + s3 (pre-B1 behaviour).
            S3_CERT_NAME="bebop-${TENANT_ID}"
        fi
    else
        S3_DOMAIN=""
        S3_CERT_NAME=""
        GARAGE_BUCKET=""
        GARAGE_KEY_NAME=""
    fi
    MONGO_DB_NAME="bebop_${TENANT_ID//-/_}"

    if [[ "${DECISION_PATH:-fresh}" == "fresh" ]]; then
        BEBOP_PORT=$(registry_allocate_port bebop)
        PHOENIXD_PORT=$(registry_allocate_port phoenixd)
        MONGO_PORT=$(registry_allocate_port mongo)
    else
        BEBOP_PORT=$(registry_get_field "$TENANT_ID" bebop_port)
        PHOENIXD_PORT=$(registry_get_field "$TENANT_ID" phoenixd_port)
        MONGO_PORT=$(registry_get_field "$TENANT_ID" mongo_port)
    fi
    log_info "ports: bebop=${BEBOP_PORT}, phoenixd=${PHOENIXD_PORT}, mongo=${MONGO_PORT}"
    log_info "domain: https://${DOMAIN} (S3: https://${S3_DOMAIN})"
}

# Phase 2.5: clean any orphan resources from a prior failed fresh run.
#
# The transactional rollback in run_fresh_creation walks the undo stack
# in reverse, but only undoes steps that completed AND registered their
# undo. A failure mid-step (e.g. garage_key_create succeeds then the
# script is killed before the undo registers; or a phase fails before
# its half-created resources are tracked) leaves the system with
# orphan state that breaks the next add-tenant attempt.
#
# This phase only runs in DECISION_PATH=fresh (tenant absent from
# registry) — by definition no live service references these orphans
# so destruction is safe. We don't call this from reactivate/reapply
# paths, where every resource we'd find IS the live one.
phase_clean_orphans() {
    log_info "phase 2.5: scanning for orphan resources from prior failed runs..."
    local cleaned=0
    # OVH DNS records:
    #   - main: only checked when NOT external (otherwise it's in another zone).
    #   - s3:   only checked when has_local_s3 (otherwise we never created one).
    local id
    if ! is_external_mode; then
        id=$(ovh_dns_record_find "$TENANT_ID" A 2>/dev/null || true)
        if [[ -n "$id" ]]; then
            log_warn "orphan: DNS A ${DOMAIN} (id=${id}); deleting"
            ovh_dns_record_delete "$id" || log_warn "orphan: DNS delete failed for ${id} — continuing"
            cleaned=1
        fi
    fi
    if has_local_s3; then
        id=$(ovh_dns_record_find "s3.${TENANT_ID}" A 2>/dev/null || true)
        if [[ -n "$id" ]]; then
            log_warn "orphan: DNS A ${S3_DOMAIN} (id=${id}); deleting"
            ovh_dns_record_delete "$id" || log_warn "orphan: DNS delete failed for ${id} — continuing"
            cleaned=1
        fi
    fi
    [[ "$cleaned" == 1 ]] && ovh_dns_zone_refresh

    # Stale systemd units (still enabled / active from a previous run).
    local unit
    for unit in "bebop@${TENANT_ID}.service" "phoenixd@${TENANT_ID}.service" "mongod@${TENANT_ID}.service"; do
        if run_privileged systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q .; then
            if run_privileged systemctl is-active --quiet "$unit" 2>/dev/null \
               || run_privileged systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                log_warn "orphan: systemd unit ${unit}; disabling"
                run_privileged systemctl disable --now "$unit" 2>/dev/null || true
            fi
        fi
    done

    # phoenixd orphan listening on the port we're about to allocate. A
    # previously-purged tenant can leave a phoenixd process detached from
    # its systemd unit (see lib/phoenixd.sh for why); without this kill,
    # the new phoenixd@<TENANT_ID> would EADDRINUSE-loop on first start.
    phoenixd_kill_orphans "$PHOENIXD_PORT"

    # Local state + config dirs.
    local dir
    for dir in \
        "/var/lib/be-BOP/${TENANT_ID}" \
        "/etc/be-BOP/${TENANT_ID}" \
        "/var/lib/be-BOP-mongodb/${TENANT_ID}" \
        "/etc/be-BOP-mongodb/${TENANT_ID}" \
        "/var/lib/phoenixd/${TENANT_ID}" \
        "/etc/phoenixd/${TENANT_ID}"; do
        if run_privileged test -d "$dir"; then
            log_warn "orphan: ${dir}; removing"
            run_privileged rm -rf "$dir"
        fi
    done

    # Garage bucket + key. Only relevant when has_local_s3 — without it,
    # GARAGE_KEY_NAME / GARAGE_BUCKET are empty and there's nothing to clean.
    if has_local_s3; then
        if garage_key_exists "$GARAGE_KEY_NAME"; then
            log_warn "orphan: garage key '${GARAGE_KEY_NAME}'; deleting"
            garage_key_delete "$GARAGE_KEY_NAME"
        fi
        if garage_bucket_exists "$GARAGE_BUCKET"; then
            log_warn "orphan: garage bucket '${GARAGE_BUCKET}'; deleting"
            garage_bucket_delete "$GARAGE_BUCKET"
        fi
    fi

    # nginx vhost (sites-available + sites-enabled symlink).
    if run_privileged test -e "/etc/nginx/sites-available/bebop-${TENANT_ID}.conf"; then
        log_warn "orphan: nginx vhost bebop-${TENANT_ID}; removing"
        run_privileged rm -f \
            "/etc/nginx/sites-enabled/bebop-${TENANT_ID}.conf" \
            "/etc/nginx/sites-available/bebop-${TENANT_ID}.conf"
        run_privileged systemctl reload nginx 2>/dev/null || true
    fi

    # Let's Encrypt cert directories. Walks all possible cert names:
    #   - main: bebop-<id>                  (always)
    #   - s3:   bebop-<id>-s3               (only when external + has_local_s3)
    # In internal+has_local_s3 mode the cert is a SAN under bebop-<id> only,
    # so the second name is empty / skipped. In --no-local-s3 mode there's
    # no S3 cert at all.
    local _c
    for _c in "$CERT_NAME" "$S3_CERT_NAME"; do
        if [[ -n "$_c" && "$_c" != "$CERT_NAME-DUMMY" ]] && \
           [[ "$_c" != "$CERT_NAME" || "${_seen_main:-}" != "1" ]] && \
           run_privileged test -d "/etc/letsencrypt/live/${_c}"; then
            log_warn "orphan: Let's Encrypt cert ${_c}; deleting"
            run_privileged certbot delete --non-interactive --cert-name "${_c}" 2>/dev/null \
                || log_warn "orphan: certbot delete failed for ${_c}; continuing"
        fi
        [[ "$_c" == "$CERT_NAME" ]] && _seen_main=1
    done
    unset _c _seen_main

    # Kuma monitor (best-effort; helper warns if creds/URL missing).
    kuma_unregister_tenant "$TENANT_ID" 2>/dev/null || true

    log_info "phase 2.5: orphan cleanup complete"
}

# Phase 3: DNS records.
# - Internal mode: create A records via OVH for both <tenant>.<zone> and
#   s3.<tenant>.<zone>.
# - External mode: skip the main domain (operator manages it on their own
#   provider); pre-flight check that A AND AAAA on <external_domain> match
#   the VDS's IPs (abort with actionable message otherwise). Still create
#   the S3 OVH record since S3 stays on our zone.
phase_dns() {
    if is_external_mode; then
        log_info "phase 3: pre-flight DNS check on external domain ${DOMAIN}..."
        detect_host_ipv6
        dns_check_external_fqdn "$DOMAIN" "$HOST_IP" "$HOST_IPV6"
        log_info "phase 3: external DNS OK (main is operator-managed)"
        DNS_RECORD_BEBOP_ID=""
    else
        log_info "phase 3: DNS A record via OVH (main)..."
        DNS_RECORD_BEBOP_ID=$(ovh_dns_record_create "$TENANT_ID" A "$HOST_IP")
        txn_register_undo "DNS A record ${DOMAIN}" \
            "ovh_dns_record_delete '${DNS_RECORD_BEBOP_ID}' && ovh_dns_zone_refresh"
    fi
    # S3 OVH record: only when has_local_s3 (the s3.<tenant>.<zone> hostname
    # points at our Garage; with --no-local-s3 there's no Garage to point at).
    if has_local_s3; then
        DNS_RECORD_S3_ID=$(ovh_dns_record_create "s3.${TENANT_ID}" A "$HOST_IP")
        txn_register_undo "DNS A record ${S3_DOMAIN}" \
            "ovh_dns_record_delete '${DNS_RECORD_S3_ID}' && ovh_dns_zone_refresh"
    else
        DNS_RECORD_S3_ID=""
        log_info "phase 3: --no-local-s3 → skipping S3 OVH record creation"
    fi
    ovh_dns_zone_refresh
    log_info "DNS records pushed; OVH propagates them to authoritative NS within ~30s"
}

# Phase 4: per-tenant local mongod (port.env + start unit + init RS)
phase_mongo() {
    log_info "phase 4: per-tenant mongod (port=${MONGO_PORT})..."
    # Write port.env BEFORE starting the unit (EnvironmentFile= reads it).
    run_privileged install -d -m 0755 "/etc/be-BOP-mongodb/${TENANT_ID}"
    local tmp
    tmp=$(mktemp)
    printf 'MONGO_PORT=%s\n' "$MONGO_PORT" > "$tmp"
    run_privileged install -m 0640 "$tmp" "/etc/be-BOP-mongodb/${TENANT_ID}/port.env"
    rm -f "$tmp"
    txn_register_undo "mongod port.env" \
        "run_privileged rm -rf '/etc/be-BOP-mongodb/${TENANT_ID}'"

    run_privileged systemctl enable --now "mongod@${TENANT_ID}.service"
    txn_register_undo "mongod@${TENANT_ID}.service" \
        "run_privileged systemctl disable --now 'mongod@${TENANT_ID}.service' 2>/dev/null || true; run_privileged rm -rf '/var/lib/be-BOP-mongodb/${TENANT_ID}'"

    if [[ "$DRY_RUN" != "true" ]]; then
        mongo_wait_ready "$MONGO_PORT" 60 1 \
            || die "mongod@${TENANT_ID} did not become ready on 127.0.0.1:${MONGO_PORT} within 60s (check 'journalctl -u mongod@${TENANT_ID}')"
        mongo_init_rs "$MONGO_PORT"
    fi
    MONGO_URL=$(mongo_build_url "$MONGO_PORT" "$MONGO_DB_NAME")
    log_info "Mongo: db=${MONGO_DB_NAME} on 127.0.0.1:${MONGO_PORT} (rs=rs0)"
}

# Phase 5: Garage bucket + key + grant + quota
phase_garage() {
    if ! has_local_s3; then
        log_info "phase 5: --no-local-s3 → skipping local Garage provisioning"
        return 0
    fi
    log_info "phase 5: Garage bucket + key + quota..."
    garage_bucket_create "$GARAGE_BUCKET"
    txn_register_undo "Garage bucket ${GARAGE_BUCKET}" \
        "garage_bucket_delete '${GARAGE_BUCKET}'"
    local key_out
    key_out=$(garage_key_create "$GARAGE_KEY_NAME")
    GARAGE_KEY_ID=$(printf '%s' "$key_out" | cut -f1)
    GARAGE_KEY_SECRET=$(printf '%s' "$key_out" | cut -f2)
    txn_register_undo "Garage key ${GARAGE_KEY_NAME}" \
        "garage_key_delete '${GARAGE_KEY_NAME}'"
    garage_bucket_grant "$GARAGE_BUCKET" "$GARAGE_KEY_NAME"
    garage_bucket_set_quota "$GARAGE_BUCKET" "$DEFAULT_BUCKET_QUOTA"
    log_info "Garage: bucket=${GARAGE_BUCKET}, key id=${GARAGE_KEY_ID}, quota=${DEFAULT_BUCKET_QUOTA}"
}

# Phase 6: per-tenant filesystem skeleton
#
# We deliberately do NOT pre-create the StateDirectory targets
# (/var/lib/phoenixd/<id>, /var/lib/be-BOP-mongodb/<id>, /var/lib/be-BOP/<id>/state).
# systemd's StateDirectory= sets these up with the right mode (0700) and
# owner (DynamicUser) on first service start; pre-creating them as
# root:root 0755 makes systemd fail with status=238/STATE_DIRECTORY
# ("Failed to set up special execution directory").
# We only create what bebop@.service expects to already exist (the
# release tree under /var/lib/be-BOP/<id>/releases/) and the per-tenant
# /etc/ trees that hold port.env / config.env.
phase_directories() {
    log_info "phase 6: directory skeleton for tenant..."
    run_privileged install -d -m 0755 "/var/lib/be-BOP/${TENANT_ID}"
    run_privileged install -d -m 0755 "/var/lib/be-BOP/${TENANT_ID}/releases"
    run_privileged install -d -m 0755 "/etc/be-BOP/${TENANT_ID}"
    if [[ "$ENABLE_PHOENIXD" == "true" ]]; then
        run_privileged install -d -m 0755 "/etc/phoenixd/${TENANT_ID}"
    fi
    txn_register_undo "tenant directory tree" \
        "run_privileged rm -rf '/var/lib/be-BOP/${TENANT_ID}' '/etc/be-BOP/${TENANT_ID}' '/etc/phoenixd/${TENANT_ID}' '/var/lib/phoenixd/${TENANT_ID}'"
}

# Phase 7: ensure host-shared release cache, then symlink tenant→cache.
# We DO NOT register an undo for the cache entry: it's shared across tenants
# and another tenant may already point to it. B2 (purge) handles orphan
# cache entries separately. The tenant-side symlink IS undoable.
phase_release() {
    log_info "phase 7: be-BOP release ${BEBOP_VERSION}..."
    RESOLVED_VERSION=$(release_resolve_version "$BEBOP_VERSION")
    log_info "resolved version: ${RESOLVED_VERSION}"
    release_cache_ensure "$RESOLVED_VERSION"
    release_cache_set_current "$TENANT_ID" "$RESOLVED_VERSION"
    txn_register_undo "tenant current symlink" \
        "run_privileged rm -f '/var/lib/be-BOP/${TENANT_ID}/releases/current'"
}

# Phase 8: phoenixd port.env + start phoenixd + read http-password
phase_phoenixd() {
    if [[ "$ENABLE_PHOENIXD" != "true" ]]; then
        log_info "phase 8: phoenixd disabled (--no-phoenixd) — skipping"
        return 0
    fi
    log_info "phase 8: phoenixd ${TENANT_ID}..."
    local tmp
    tmp=$(mktemp)
    printf 'PHOENIXD_PORT=%s\n' "$PHOENIXD_PORT" > "$tmp"
    run_privileged install -m 0640 "$tmp" "/etc/phoenixd/${TENANT_ID}/port.env"
    rm -f "$tmp"
    txn_register_undo "phoenixd port.env" \
        "run_privileged rm -f '/etc/phoenixd/${TENANT_ID}/port.env'"

    run_privileged systemctl enable --now "phoenixd@${TENANT_ID}.service"
    txn_register_undo "phoenixd@${TENANT_ID}.service" \
        "run_privileged systemctl disable --now 'phoenixd@${TENANT_ID}.service' 2>/dev/null || true"

    # Wait for phoenix.conf to be readable AND contain http-password.
    local conf="/var/lib/phoenixd/${TENANT_ID}/.phoenix/phoenix.conf"
    local i pwd
    log_info "waiting for phoenix.conf at ${conf}..."
    for (( i=1; i<=PHOENIXD_PASSWORD_RETRIES; i++ )); do
        if run_privileged test -r "$conf"; then
            pwd=$(run_privileged grep -oP '^http-password=\K\S+' "$conf" 2>/dev/null || true)
            if [[ -n "$pwd" ]]; then
                PHOENIXD_HTTP_PASSWORD="$pwd"
                break
            fi
        fi
        log_debug "phoenix.conf not ready (try ${i}/${PHOENIXD_PASSWORD_RETRIES}); waiting ${PHOENIXD_PASSWORD_INTERVAL}s"
        (( i < PHOENIXD_PASSWORD_RETRIES )) && sleep "$PHOENIXD_PASSWORD_INTERVAL"
    done
    if [[ -z "$PHOENIXD_HTTP_PASSWORD" ]]; then
        die "phoenixd: could not obtain http-password from ${conf} within $((PHOENIXD_PASSWORD_RETRIES * PHOENIXD_PASSWORD_INTERVAL))s"
    fi
    # Read seed for operator output (best-effort).
    local seed_file="/var/lib/phoenixd/${TENANT_ID}/.phoenix/seed.dat"
    if run_privileged test -r "$seed_file"; then
        PHOENIXD_SEED_HEX=$(run_privileged xxd -p -c 256 "$seed_file" 2>/dev/null || true)
    fi
    log_info "phoenixd ${TENANT_ID} ready (http-password obtained)"
}

# Phase 9: per-tenant config.env
# Render assembly: main fragment + optionally s3 fragment + scissor marker
# + preserved operator custom block (if any). The marker isn't in any
# template — it's added literally so we can keep main / s3 as standalone
# auditable env-file fragments. has_local_s3 toggles the s3 fragment.
phase_config_env() {
    log_info "phase 9: writing /etc/be-BOP/${TENANT_ID}/config.env..."
    local tmp existing_custom=""
    tmp=$(mktemp)
    local target="/etc/be-BOP/${TENANT_ID}/config.env"
    local marker='# ------------------------ >8 ------------------------'
    if run_privileged test -f "$target"; then
        existing_custom=$(run_privileged sed -n "/^${marker}\$/,\$p" "$target" 2>/dev/null || true)
    fi
    # 1. Main fragment.
    render_template "${BEBOP_TOOLING_TEMPLATE_DIR}/config.env-main.tmpl" \
        bebop_port              "$BEBOP_PORT" \
        domain                  "$DOMAIN" \
        mongodb_url             "$MONGO_URL" \
        mongodb_database        "$MONGO_DB_NAME" \
        phoenixd_port           "$PHOENIXD_PORT" \
        phoenixd_http_password  "$PHOENIXD_HTTP_PASSWORD" \
        template_revision       "$TEMPLATE_REVISION" \
        > "$tmp"
    # 2. S3 fragment, only when has_local_s3.
    if has_local_s3; then
        render_template "${BEBOP_TOOLING_TEMPLATE_DIR}/config.env-s3.tmpl" \
            s3_domain          "$S3_DOMAIN" \
            garage_bucket      "$GARAGE_BUCKET" \
            garage_key_id      "$GARAGE_KEY_ID" \
            garage_key_secret  "$GARAGE_KEY_SECRET" \
            >> "$tmp"
    fi
    # 3. Scissor marker + preserved operator customs.
    if [[ -n "$existing_custom" ]]; then
        printf '\n%s\n' "$existing_custom" >> "$tmp"
    else
        printf '\n%s\n# Put your custom configuration (even new environment variables) after this line.\n# Anything ABOVE this marker is overwritten on every re-run of add-tenant.sh\n# or upgrade-tenant.sh; everything BELOW is preserved.\n' \
            "$marker" >> "$tmp"
    fi
    run_privileged install -d -m 0755 "/etc/be-BOP/${TENANT_ID}"
    run_privileged install -m 0640 "$tmp" "$target"
    rm -f "$tmp"
    txn_register_undo "config.env ${TENANT_ID}" \
        "run_privileged rm -f '${target}'"
    log_info "config.env installed (mode 0640)"
}

# Phase 10: TLS cert (per-tenant SAN, DNS-01 via custom OVH hook)
#
# We use certbot --manual + our own auth/cleanup hooks instead of the
# certbot-dns-ovh plugin. The plugin requires an OVH token scoped to
# /domain/* (it lists all zones for auto-discovery); our hooks know
# the zone from secrets.env and only need GET/POST/DELETE under
# /domain/zone/<OVH_DNS_ZONE>/* — strictly tenant-scoped.
phase_certificate() {
    local hooks_dir="/usr/local/share/be-BOP-tooling/hooks"
    if [[ -d "${SCRIPT_DIR}/hooks" ]]; then
        hooks_dir="${SCRIPT_DIR}/hooks"
    fi
    # The LE account email is always the per-tenant --admin-email. This
    # consumes one of LE's "10 accounts / IP / 3h" slots per unique address,
    # which matters at high churn (test-tenant deploy API spawning many
    # ephemeral tenants from distinct buyer emails). If you hit the limit,
    # rate-limit the spawn shop upstream.
    local acme_email="$ADMIN_EMAIL"

    # Four combinations:
    #   external + has_local_s3 : main HTTP-01  + s3 DNS-01  (two certs)
    #   external + no_local_s3  : main HTTP-01  only         (one cert)
    #   internal + has_local_s3 : SAN DNS-01    main+s3      (one cert)
    #   internal + no_local_s3  : main DNS-01   only         (one cert)
    if is_external_mode; then
        if has_local_s3; then
            log_info "phase 10: Let's Encrypt certs (external + s3 = HTTP-01 main + DNS-01 s3)..."
            _issue_cert_http01 "$CERT_NAME"    "$DOMAIN"    "$acme_email"
            _issue_cert_dns01  "$S3_CERT_NAME" "$S3_DOMAIN" "$acme_email" "$hooks_dir"
        else
            log_info "phase 10: Let's Encrypt cert (external, no-s3 = HTTP-01 main only)..."
            _issue_cert_http01 "$CERT_NAME" "$DOMAIN" "$acme_email"
        fi
    else
        if has_local_s3; then
            log_info "phase 10: Let's Encrypt cert (internal SAN DNS-01 main+s3)..."
            _issue_cert_dns01_san "$CERT_NAME" "$DOMAIN" "$S3_DOMAIN" "$acme_email" "$hooks_dir"
        else
            log_info "phase 10: Let's Encrypt cert (internal, no-s3 = DNS-01 main only)..."
            _issue_cert_dns01 "$CERT_NAME" "$DOMAIN" "$acme_email" "$hooks_dir"
        fi
    fi
}

# _issue_cert_http01 <cert_name> <domain> <acme_email>
# Single-domain HTTP-01 webroot. At INITIAL issuance, the per-tenant vhost
# doesn't exist yet (phase_certificate runs before phase_nginx), so the
# host catch-all default vhost installed by host-bootstrap.sh serves
# /.well-known/acme-challenge/ from /var/lib/letsencrypt/. At RENEWAL,
# the per-tenant vhost exists and matches server_name first — so the
# vhost itself must also serve the webroot. The catch-all is now a
# bootstrap-only fallback; the vhost template carries the load-bearing
# webroot location.
_issue_cert_http01() {
    local cert_name="$1" domain="$2" email="$3"
    if run_privileged test -d "/etc/letsencrypt/live/${cert_name}"; then
        log_info "cert ${cert_name} already issued — skipping certbot"
        return 0
    fi
    local certbot_args=(
        certonly
        --webroot --webroot-path /var/lib/letsencrypt
        --non-interactive --agree-tos
        --email "$email"
        --cert-name "$cert_name"
        -d "$domain"
    )
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run: certbot ${certbot_args[*]}"
    else
        run_privileged certbot "${certbot_args[@]}"
    fi
    txn_register_undo "Let's Encrypt cert ${cert_name}" \
        "run_privileged certbot delete --non-interactive --cert-name '${cert_name}' 2>/dev/null || true"
}

# _issue_cert_dns01 <cert_name> <domain> <acme_email> <hooks_dir>
# Single-domain DNS-01 via custom OVH hook (the same hook the SAN cert uses).
_issue_cert_dns01() {
    local cert_name="$1" domain="$2" email="$3" hooks_dir="$4"
    if run_privileged test -d "/etc/letsencrypt/live/${cert_name}"; then
        log_info "cert ${cert_name} already issued — skipping certbot"
        return 0
    fi
    local certbot_args=(
        certonly
        --manual
        --preferred-challenges dns-01
        --manual-auth-hook "${hooks_dir}/certbot-ovh-auth.sh"
        --manual-cleanup-hook "${hooks_dir}/certbot-ovh-cleanup.sh"
        --non-interactive --agree-tos
        --email "$email"
        --cert-name "$cert_name"
        -d "$domain"
    )
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run: certbot ${certbot_args[*]}"
    else
        run_privileged certbot "${certbot_args[@]}"
    fi
    txn_register_undo "Let's Encrypt cert ${cert_name}" \
        "run_privileged certbot delete --non-interactive --cert-name '${cert_name}' 2>/dev/null || true"
}

# _issue_cert_dns01_san <cert_name> <domain> <s3_domain> <acme_email> <hooks_dir>
# SAN cert covering both main and s3 — the historical internal-tenant flow.
_issue_cert_dns01_san() {
    local cert_name="$1" domain="$2" s3_domain="$3" email="$4" hooks_dir="$5"
    if run_privileged test -d "/etc/letsencrypt/live/${cert_name}"; then
        log_info "cert ${cert_name} already issued — skipping certbot"
        return 0
    fi
    local certbot_args=(
        certonly
        --manual
        --preferred-challenges dns-01
        --manual-auth-hook "${hooks_dir}/certbot-ovh-auth.sh"
        --manual-cleanup-hook "${hooks_dir}/certbot-ovh-cleanup.sh"
        --non-interactive --agree-tos
        --email "$email"
        --cert-name "$cert_name"
        -d "$domain"
        -d "$s3_domain"
    )
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run: certbot ${certbot_args[*]}"
    else
        run_privileged certbot "${certbot_args[@]}"
    fi
    txn_register_undo "Let's Encrypt cert ${cert_name}" \
        "run_privileged certbot delete --non-interactive --cert-name '${cert_name}' 2>/dev/null || true"
}

# Phase 11: nginx vhost
# Always render the main fragment. When has_local_s3, also append the s3
# fragment. http_redirect_names = "@domain@ @s3_domain@" with S3, just
# "@domain@" without — so the HTTP→HTTPS redirect block covers both
# server_names in one shot when applicable.
phase_nginx() {
    log_info "phase 11: nginx vhost..."
    local available="/etc/nginx/sites-available/bebop-${TENANT_ID}.conf"
    local enabled="/etc/nginx/sites-enabled/bebop-${TENANT_ID}.conf"
    local tmp http_redirect_names
    tmp=$(mktemp)
    if has_local_s3; then
        http_redirect_names="${DOMAIN} ${S3_DOMAIN}"
    else
        http_redirect_names="${DOMAIN}"
    fi
    render_template "${BEBOP_TOOLING_TEMPLATE_DIR}/nginx-tenant-main.conf.tmpl" \
        tenant_id            "$TENANT_ID" \
        domain               "$DOMAIN" \
        s3_domain            "${S3_DOMAIN:-}" \
        main_cert_name       "$CERT_NAME" \
        bebop_port           "$BEBOP_PORT" \
        http_redirect_names  "$http_redirect_names" \
        template_revision    "$TEMPLATE_REVISION" \
        > "$tmp"
    if has_local_s3; then
        render_template "${BEBOP_TOOLING_TEMPLATE_DIR}/nginx-tenant-s3.conf.tmpl" \
            tenant_id          "$TENANT_ID" \
            s3_domain          "$S3_DOMAIN" \
            s3_cert_name       "$S3_CERT_NAME" \
            template_revision  "$TEMPLATE_REVISION" \
            >> "$tmp"
    fi
    run_privileged install -m 0644 "$tmp" "$available"
    rm -f "$tmp"
    run_privileged ln -sfn "$available" "$enabled"
    txn_register_undo "nginx vhost bebop-${TENANT_ID}" \
        "run_privileged rm -f '${enabled}' '${available}' && run_privileged systemctl reload nginx"
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! run_privileged nginx -t; then
            die "nginx -t failed after writing vhost — check /etc/nginx/sites-available/bebop-${TENANT_ID}.conf"
        fi
        run_privileged systemctl reload nginx
    fi
}

# Auto-prefill runtimeConfig.smtp from the host-wide SMTP_* env vars (as loaded
# from secrets.env). be-BOP reads this entry as a nested object — be careful to
# upsert an actual object, not a JSON-stringified scalar. No-op when SMTP_HOST
# is empty (operator opted out / not configured yet).
#
# The host-wide SMTP_TO is intentionally NOT propagated: it's used for tooling-
# alert recipients (notify.sh), not for the tenant's outbound shop mail flow.
apply_smtp_prefill() {
    if [[ -z "${SMTP_HOST:-}" ]]; then
        log_debug "smtp prefill: SMTP_HOST empty in secrets.env → skipping"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would prefill runtimeConfig.smtp from SMTP_* env vars"
        return 0
    fi
    if ! mongo_wait_ready "$MONGO_PORT" 60 1; then
        die "smtp prefill: mongod@${TENANT_ID} not ready on port ${MONGO_PORT}"
    fi
    local smtp_json
    # `jq -n` builds the object; `port` is cast to a number because be-BOP's
    # nodemailer config expects `port: 587` (number), not `port: "587"`.
    smtp_json=$(jq -nc \
        --arg h "$SMTP_HOST" \
        --arg p "${SMTP_PORT:-587}" \
        --arg u "${SMTP_USER:-}" \
        --arg w "${SMTP_PASSWORD:-}" \
        --arg f "${SMTP_FROM:-${SMTP_USER:-}}" \
        '{host: $h, port: ($p | tonumber), user: $u, password: $w, from: $f, fake: false}'
    )
    mongo_runtime_config_upsert_obj "$MONGO_PORT" "$MONGO_DB_NAME" smtp "$smtp_json" false \
        || die "smtp prefill: upsert failed"
}

# Applies operator-supplied --runtime-config / --runtime-config-locked entries
# to the tenant's runtimeConfig collection. Called right before bebop starts
# so the daemon's first read picks up our overrides. No-op when the operator
# passed no overrides.
apply_runtime_config_overrides() {
    [[ ${#RUNTIME_CONFIG_OVERRIDES[@]} -eq 0 ]] && return 0
    log_info "applying ${#RUNTIME_CONFIG_OVERRIDES[@]} runtime-config override(s)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local entry
        for entry in "${RUNTIME_CONFIG_OVERRIDES[@]}"; do
            log_info "[dry-run] runtime-config: ${entry}"
        done
        return 0
    fi
    if ! mongo_wait_ready "$MONGO_PORT" 60 1; then
        die "runtime-config: mongod@${TENANT_ID} not ready on port ${MONGO_PORT}"
    fi
    local entry lock rest key value
    for entry in "${RUNTIME_CONFIG_OVERRIDES[@]}"; do
        lock="${entry%%:*}"
        rest="${entry#*:}"
        key="${rest%%=*}"
        value="${rest#*=}"
        mongo_runtime_config_upsert "$MONGO_PORT" "$MONGO_DB_NAME" "$key" "$value" "$lock" \
            || die "runtime-config: upsert failed for ${key}"
    done
}

# Phase 12: bebop service
phase_bebop_service() {
    log_info "phase 12: bebop@${TENANT_ID}.service..."
    apply_smtp_prefill
    apply_runtime_config_overrides
    run_privileged systemctl enable --now "bebop@${TENANT_ID}.service"
    txn_register_undo "bebop@${TENANT_ID}.service" \
        "run_privileged systemctl disable --now 'bebop@${TENANT_ID}.service' 2>/dev/null || true"
}

# Phase 13: HTTP healthcheck
#
# For external-domain tenants, we bypass the VDS's local resolver via
# `curl --resolve` and direct curl at the host IPs we already validated
# against the authoritative NS in phase 3. Without this, the healthcheck
# routinely fails because the operator just set their public DNS and the
# system resolver still has a negative cache — even though the zone IS
# correctly published (proved by the auth-NS check). For internal tenants
# we keep using the system resolver (OVH propagation is fast enough on
# our zone).
phase_healthcheck() {
    log_info "phase 13: healthcheck https://${DOMAIN}/..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] skipping healthcheck"
        return 0
    fi
    local healthcheck_extra=()
    if is_external_mode; then
        # phase_dns called detect_host_ipv6 already on fresh / reactivate;
        # run_reapply doesn't run phase_dns, so re-detect defensively here.
        [[ -z "$HOST_IPV6" ]] && detect_host_ipv6
        healthcheck_extra=( --resolve "${DOMAIN}:443:${HOST_IP},${HOST_IPV6}" )
        log_info "external mode: --resolve ${DOMAIN}:443:${HOST_IP},${HOST_IPV6} (bypassing local resolver cache)"
    fi
    if ! http_wait_ok "https://${DOMAIN}/" "$HEALTHCHECK_RETRIES" "$HEALTHCHECK_INTERVAL" \
            "${healthcheck_extra[@]+"${healthcheck_extra[@]}"}"; then
        die "healthcheck failed for https://${DOMAIN}/ (service may have crashed; check 'journalctl -u bebop@${TENANT_ID}')"
    fi
    log_info "healthcheck OK ✓"
}

# Phase 14: Uptime Kuma + registry update
phase_kuma_and_registry() {
    log_info "phase 14: Uptime Kuma registration + registry write..."
    kuma_register_tenant "$TENANT_ID" "https://${DOMAIN}/"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    case "${DECISION_PATH:-fresh}" in
        fresh)
            registry_add \
                "$TENANT_ID" "$DOMAIN" "$BEBOP_PORT" "$PHOENIXD_PORT" \
                "$MONGO_PORT" "$MONGO_DB_NAME" \
                "$GARAGE_BUCKET" "$GARAGE_KEY_NAME" \
                "$RESOLVED_VERSION" "$now" "active"
            ;;
        reactivate)
            registry_set_status "$TENANT_ID" active
            ;;
        reapply)
            # Already active; refresh version if it changed.
            registry_set_field "$TENANT_ID" bebop_version "$RESOLVED_VERSION"
            ;;
    esac
}

# Phase 15: success summary + operator output
phase_summary() {
    cat <<EOF

==========================================================================
  Tenant '${TENANT_ID}' is ${DECISION_PATH:-active}
==========================================================================

  Public URL:             https://${DOMAIN}/
  S3 endpoint (public):   $(if has_local_s3; then echo "https://${S3_DOMAIN}/"; else echo "(none — --no-local-s3; configure external S3 via the be-BOP UI)"; fi)
  be-BOP version:         ${RESOLVED_VERSION:-unchanged}
  bebop port (local):     ${BEBOP_PORT}
  phoenixd port (local):  ${PHOENIXD_PORT}
  mongod port (local):    ${MONGO_PORT}

  Per-tenant config:      /etc/be-BOP/${TENANT_ID}/config.env
  Per-tenant releases:    /var/lib/be-BOP/${TENANT_ID}/releases/
  Phoenixd state:         /var/lib/phoenixd/${TENANT_ID}/.phoenix/
  Mongo state:            /var/lib/be-BOP-mongodb/${TENANT_ID}/

  systemd units:          systemctl status bebop@${TENANT_ID} phoenixd@${TENANT_ID} mongod@${TENANT_ID}
  logs:                   journalctl -u bebop@${TENANT_ID} -u phoenixd@${TENANT_ID} -u mongod@${TENANT_ID}

EOF
    if [[ "${DECISION_PATH:-fresh}" == "fresh" && "$ENABLE_PHOENIXD" == "true" ]]; then
        cat <<EOF
  ==== TRANSMIT TO MERCHANT (sensitive — handle carefully) ====
  phoenixd HTTP password:   ${PHOENIXD_HTTP_PASSWORD}
  phoenixd seed (hex):      ${PHOENIXD_SEED_HEX:-(seed.dat not readable)}

  These credentials control the merchant's Lightning wallet. Store them in
  the merchant's password manager and back the seed up off-host (encrypted).

EOF
    fi
}

# === Decision path implementations ======================================

run_fresh_creation() {
    DECISION_PATH=fresh
    txn_init
    detect_host_ip
    phase_derive_identifiers
    phase_clean_orphans
    phase_dns
    phase_mongo
    phase_garage
    phase_directories
    phase_release
    phase_phoenixd
    phase_config_env
    phase_certificate
    phase_nginx
    phase_bebop_service
    phase_healthcheck
    phase_kuma_and_registry
    txn_commit
    NOTIFIED=true
    notify_success \
        "[be-BOP tooling] add-tenant ${TENANT_ID} OK" \
        "Tenant ${TENANT_ID} is now active at https://${DOMAIN}/ (be-BOP ${RESOLVED_VERSION})."
    phase_summary
}

run_reactivation() {
    DECISION_PATH=reactivate
    txn_init
    detect_host_ip
    phase_derive_identifiers   # ports re-read from registry
    # Skipped on reactivation: phase_garage, phase_directories,
    # phase_release, phase_phoenixd (services, port.env, seeds intact).
    phase_dns
    # Restart the per-tenant mongod (it was stopped during soft-delete; data
    # in /var/lib/be-BOP-mongodb/<tenant> is intact).
    run_privileged systemctl enable --now "mongod@${TENANT_ID}.service"
    if [[ "$DRY_RUN" != "true" ]]; then
        mongo_wait_ready "$MONGO_PORT" 60 1 \
            || die "mongod@${TENANT_ID} did not become ready on reactivation"
    fi
    # RS init: handled by bebop-mongo-preflight.sh at bebop@ startup —
    # ExecStartPre in bebop@.service. Single point of guard.
    # Re-read existing phoenixd password from disk (no recreation).
    if [[ "$ENABLE_PHOENIXD" == "true" ]]; then
        local conf="/var/lib/phoenixd/${TENANT_ID}/.phoenix/phoenix.conf"
        if run_privileged test -r "$conf"; then
            PHOENIXD_HTTP_PASSWORD=$(run_privileged grep -oP '^http-password=\K\S+' "$conf" 2>/dev/null || true)
        fi
    fi
    # Rebuild the local MONGO_URL from registry-stored port + db name.
    MONGO_URL=$(mongo_build_url "$MONGO_PORT" "$MONGO_DB_NAME")
    # Pull existing Garage creds (we don't recreate the key; secret is unknown).
    if run_privileged test -f "/etc/be-BOP/${TENANT_ID}/config.env"; then
        GARAGE_KEY_ID=$(run_privileged grep -oP '^S3_KEY_ID=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
        GARAGE_KEY_SECRET=$(run_privileged grep -oP '^S3_KEY_SECRET=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
    fi
    phase_config_env       # rewrites with current vars (preserves >8 customisations)
    phase_certificate      # idempotent: skip if cert dir exists
    phase_nginx
    if [[ "$ENABLE_PHOENIXD" == "true" ]]; then
        run_privileged systemctl enable --now "phoenixd@${TENANT_ID}.service"
    fi
    phase_bebop_service
    phase_healthcheck
    phase_kuma_and_registry
    txn_commit
    NOTIFIED=true
    notify_success \
        "[be-BOP tooling] reactivate ${TENANT_ID} OK" \
        "Tenant ${TENANT_ID} restored at https://${DOMAIN}/."
    phase_summary
}

run_reapply() {
    DECISION_PATH=reapply
    # Idempotent: no rollback needed (we only rewrite config + reload).
    detect_host_ip
    phase_derive_identifiers
    # mongod boot + RS init are guaranteed by bebop-mongo-preflight.sh at
    # bebop@ startup (ExecStartPre). Nothing to do here — the systemctl
    # restart at phase 12 will trigger the preflight.
    MONGO_URL=$(mongo_build_url "$MONGO_PORT" "$MONGO_DB_NAME")
    # Re-derive existing Garage creds + phoenixd password from current config.env.
    if run_privileged test -f "/etc/be-BOP/${TENANT_ID}/config.env"; then
        GARAGE_KEY_ID=$(run_privileged grep -oP '^S3_KEY_ID=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
        GARAGE_KEY_SECRET=$(run_privileged grep -oP '^S3_KEY_SECRET=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
        PHOENIXD_HTTP_PASSWORD=$(run_privileged grep -oP '^PHOENIXD_HTTP_PASSWORD=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
    fi
    if [[ "$BEBOP_VERSION" != "latest" || -z "$(release_get_current_tag "$TENANT_ID")" ]]; then
        phase_release
    else
        RESOLVED_VERSION=$(release_get_current_tag "$TENANT_ID")
    fi
    phase_config_env
    phase_certificate
    phase_nginx
    apply_smtp_prefill
    apply_runtime_config_overrides
    run_privileged systemctl restart "bebop@${TENANT_ID}.service"
    phase_healthcheck
    phase_kuma_and_registry
    NOTIFIED=true
    notify_success \
        "[be-BOP tooling] re-apply ${TENANT_ID} OK" \
        "Tenant ${TENANT_ID} configuration refreshed (version: ${RESOLVED_VERSION})."
    phase_summary
}

# (on_script_exit and the EXIT trap are defined near the top of the script,
# right after the lib sources, so they are in scope from very early — see
# the `=== EXIT trap ===` section.)

# === Main ===============================================================
# Preflight: sweep any orphaned tenant artefacts BEFORE we start allocating
# ports or spinning up services. registry_allocate_port scans only the
# registry, so an orphan's port would appear free and be handed out — the
# new tenant then fails at EADDRINUSE. Auto-purge closes that class of
# failure without operator intervention.
preflight_purge_orphans() {
    log_info "preflight: scan + auto-purge of orphans..."
    if ! find-orphans.sh --purge-all --yes 2>&1; then
        log_warn "preflight: find-orphans --purge-all returned non-zero (continuing)"
    fi
}

main() {
    require_privileges

    if [[ ! -f "$SECRETS_FILE" ]]; then
        die "secrets file not found: ${SECRETS_FILE}"
    fi
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"

    registry_init
    registry_lock
    # (registry_unlock is called from on_script_exit — the script-level
    # EXIT trap defined near the top — so it runs after success notif
    # AND after failure notif, on every exit path.)

    preflight_purge_orphans

    phase_status_decision

    case "${DECISION_PATH:-fresh}" in
        fresh)      run_fresh_creation ;;
        reactivate) run_reactivation ;;
        reapply)    run_reapply ;;
        *) die "internal error: unknown DECISION_PATH" ;;
    esac
}

main "$@"

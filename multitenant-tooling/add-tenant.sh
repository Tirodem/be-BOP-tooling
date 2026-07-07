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
# shellcheck source=lib/dns_provider.sh
source "$BEBOP_TOOLING_LIB_DIR/dns_provider.sh"
# shellcheck source=lib/nginx.sh
source "$BEBOP_TOOLING_LIB_DIR/nginx.sh"
# shellcheck source=lib/scaleway.sh
source "$BEBOP_TOOLING_LIB_DIR/scaleway.sh"
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
            "$(txn_size 2>/dev/null || echo 0)" "${BEBOP_TOOLING_SYSLOG_IDENT:-tooling-add-tenant}")
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
    tooling
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
DEPLOY_DEFAULT_FILE=/etc/be-BOP-tooling/deploy-default.json
TENANT_ID=""
ADMIN_EMAIL=""
EXTERNAL_DOMAIN=""    # set by --external-domain <fqdn>; empty = internal tenant
# 3-state knobs: "" = not set by CLI (fall back to deploy-default.json then
# hardcoded true), "true" / "false" = explicit CLI override.
# Populated by apply_deploy_defaults() after loading the JSON.
NO_LOCAL_S3=""        # set by --local-s3 / --no-local-s3
ENABLE_PHOENIXD=""    # set by --phoenixd / --no-phoenixd
ENABLE_MAIL_RELAY=""  # set by --mail-relay / --no-mail-relay
# Per-source profile (optional) — passed by tooling-tenant-api.service
# when the webhook lands on /deploy-test-tenant/<source-domain>, or
# manually via --profile <name>. Resolved against
# deploy-default.json.profiles[<name>] to prepend runtimeConfig
# overrides. Empty = no profile.
PROFILE=""
# Let's Encrypt staging mode. Use for repeated test provisionings so we
# don't burn through prod's "5 duplicate certs per exact identifiers per
# week" rate limit. Set via --staging on the CLI or BEBOP_LE_STAGING=true
# in secrets.env. Staging certs are NOT trusted by browsers — do not
# enable on tenants that will actually serve real traffic.
: "${BEBOP_LE_STAGING:=false}"
LE_STAGING="$BEBOP_LE_STAGING"
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
  --phoenixd / --no-phoenixd
                          override the host default for the per-tenant
                          phoenixd daemon (BEBOP_TENANT_DEFAULT_PHOENIXD
                          in deploy-default.env)
  --local-s3 / --no-local-s3
                          override the host default for local Garage
                          bucket + key provisioning (BEBOP_TENANT_DEFAULT_LOCAL_S3
                          in deploy-default.env). --no-local-s3 implies
                          no s3.<tenant>.<zone> DNS record, no S3 cert,
                          no S3 nginx block; be-BOP starts with empty
                          S3 env vars for external S3 config via the UI.
  --mail-relay / --no-mail-relay
                          override the host default for mail-relay
                          provisioning (BEBOP_TENANT_DEFAULT_MAIL_RELAY
                          in deploy-default.env). --no-mail-relay skips
                          the phase entirely — the tenant has no outbound
                          SMTP path.
  --bebop-version <tag>   GitHub release tag of be-BOP, or "latest" (default)
  --external-domain <fqdn>
                          deploy under <fqdn> instead of the default
                          <tenant_id>.<BEBOP_DNS_ZONE>. The operator MUST
                          configure both A and AAAA records on their DNS
                          provider pointing to this VDS before running.
                          The S3 endpoint stays internal at
                          s3.<tenant_id>.<BEBOP_DNS_ZONE>. The main cert is
                          issued via HTTP-01 (separate from the S3 DNS-01
                          cert). Requires public IPv6 on the VDS.
  --reactivate            restore a soft-deleted tenant (preserves data)
  --staging               issue certs against Let's Encrypt STAGING (untrusted
                          by browsers). Use for repeated test provisionings
                          to avoid burning through prod's rate limits. Also
                          settable via BEBOP_LE_STAGING=true in secrets.env.
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
        --local-s3)        NO_LOCAL_S3=false; shift ;;
        --no-local-s3)     NO_LOCAL_S3=true; shift ;;
        --mail-relay)      ENABLE_MAIL_RELAY=true; shift ;;
        --no-mail-relay)   ENABLE_MAIL_RELAY=false; shift ;;
        --profile)         PROFILE="$2"; shift 2 ;;
        --reactivate)      REACTIVATE=true; shift ;;
        --staging)         LE_STAGING=true; shift ;;
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
# under BEBOP_DNS_ZONE (= would be an internal tenant misusing the flag).
if [[ -n "$EXTERNAL_DOMAIN" ]]; then
    if [[ ! "$EXTERNAL_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
        die "invalid --external-domain '${EXTERNAL_DOMAIN}' (expected an FQDN like bebop.example.com)"
    fi
fi

is_external_mode() { [[ -n "$EXTERNAL_DOMAIN" ]]; }
has_local_s3()    { [[ "$NO_LOCAL_S3" != "true" ]]; }

# Tag log lines with the tenant id from now on.
BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
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
    ZONE="${BEBOP_DNS_ZONE:?BEBOP_DNS_ZONE missing in secrets.env}"

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
            die "--external-domain '${DOMAIN}' is under BEBOP_DNS_ZONE='${ZONE}'; drop the flag to use the standard internal path"
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
        # ATOMIC: allocate ports + insert placeholder row + register
        # rollback undo, all under a single lock. The row is written
        # with status='provisioning' + empty bebop_version — from now
        # on, any concurrent add-tenant.sh calling registry_allocate_port
        # sees these ports as taken (registry_allocate_port treats
        # `provisioning` as port-holding). Lock is released before the
        # long IO work (DNS / cert / mongo / phoenixd / kuma) so other
        # add-tenants can allocate their own ports without waiting.
        #
        # phase_kuma_and_registry flips the row to status='active' at
        # the end of the run (also under a briefly-held lock).
        _reserve_ports_and_placeholder() {
            BEBOP_PORT=$(registry_allocate_port bebop)
            PHOENIXD_PORT=$(registry_allocate_port phoenixd)
            MONGO_PORT=$(registry_allocate_port mongo)
            local now external_flag=0
            now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            is_external_mode && external_flag=1
            registry_add \
                "$TENANT_ID" "$DOMAIN" "$BEBOP_PORT" "$PHOENIXD_PORT" \
                "$MONGO_PORT" "$MONGO_DB_NAME" \
                "$GARAGE_BUCKET" "$GARAGE_KEY_NAME" \
                "" "$now" "provisioning" "$external_flag"
        }
        registry_lock_scope _reserve_ports_and_placeholder \
            || die "phase 2: failed to reserve ports + placeholder row"
        # Rollback: on failure anywhere downstream, remove the row.
        # registry_remove takes its own lock — safe from txn_run_undos
        # which runs OUTSIDE any held lock.
        txn_register_undo "registry placeholder row for ${TENANT_ID}" \
            "registry_lock_scope registry_remove '${TENANT_ID}' 2>/dev/null || true"
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
    # DNS records at the active provider (see DNS_PROVIDER):
    #   - main: only checked when NOT external (otherwise it's in another zone).
    #   - s3:   only checked when has_local_s3 (otherwise we never created one).
    local id
    if ! is_external_mode; then
        id=$(dns_provider_dns_record_find "$TENANT_ID" A 2>/dev/null || true)
        if [[ -n "$id" ]]; then
            log_warn "orphan: DNS A ${DOMAIN} (id=${id}); deleting"
            dns_provider_dns_record_delete "$id" || log_warn "orphan: DNS delete failed for ${id} — continuing"
            cleaned=1
        fi
    fi
    if has_local_s3; then
        id=$(dns_provider_dns_record_find "s3.${TENANT_ID}" A 2>/dev/null || true)
        if [[ -n "$id" ]]; then
            log_warn "orphan: DNS A ${S3_DOMAIN} (id=${id}); deleting"
            dns_provider_dns_record_delete "$id" || log_warn "orphan: DNS delete failed for ${id} — continuing"
            cleaned=1
        fi
    fi
    [[ "$cleaned" == 1 ]] && dns_provider_dns_zone_refresh

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
# - Internal mode: create A records via the DNS provider for both <tenant>.<zone> and
#   s3.<tenant>.<zone>.
# - External mode: skip the main domain (operator manages it on their own
#   provider); pre-flight check that A AND AAAA on <external_domain> match
#   the VDS's IPs (abort with actionable message otherwise). Still create
#   the S3 record since S3 stays on our zone.
phase_dns() {
    if is_external_mode; then
        log_info "phase 3: pre-flight DNS check on external domain ${DOMAIN}..."
        detect_host_ipv6
        dns_check_external_fqdn "$DOMAIN" "$HOST_IP" "$HOST_IPV6"
        log_info "phase 3: external DNS OK (main is operator-managed)"
        DNS_RECORD_BEBOP_ID=""
    else
        log_info "phase 3: DNS A record via provider (main)..."
        DNS_RECORD_BEBOP_ID=$(dns_provider_dns_record_create "$TENANT_ID" A "$HOST_IP")
        txn_register_undo "DNS A record ${DOMAIN}" \
            "dns_provider_dns_record_delete '${DNS_RECORD_BEBOP_ID}' && dns_provider_dns_zone_refresh"
    fi
    # S3 record: only when has_local_s3 (the s3.<tenant>.<zone> hostname
    # points at our Garage; with --no-local-s3 there's no Garage to point at).
    if has_local_s3; then
        DNS_RECORD_S3_ID=$(dns_provider_dns_record_create "s3.${TENANT_ID}" A "$HOST_IP")
        txn_register_undo "DNS A record ${S3_DOMAIN}" \
            "dns_provider_dns_record_delete '${DNS_RECORD_S3_ID}' && dns_provider_dns_zone_refresh"
    else
        DNS_RECORD_S3_ID=""
        log_info "phase 3: --no-local-s3 → skipping S3 DNS record creation"
    fi
    dns_provider_dns_zone_refresh
    log_info "DNS records pushed; provider propagates them to authoritative NS within ~30s"
}

# Phase 4: per-tenant local mongod (port.env + start unit + init RS)
phase_mongo() {
    log_info "phase 4: per-tenant mongod (port=${MONGO_PORT})..."
    # Write port.env WITHOUT auth first: we need the localhost exception
    # window (no --auth active yet) to create the first user. Auth gets
    # switched on further down after the user exists.
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

        # Create the tenant's SCRAM user via the localhost exception (mongod
        # still running without --auth). Then enable auth in port.env and
        # bounce mongod@ to activate --auth --keyFile. Every subsequent
        # mongosh call in this run uses the authed URI.
        MONGO_USER="bebop_${TENANT_ID//-/_}"
        MONGO_PASSWORD=$(mongo_generate_password)
        mongo_create_user "$MONGO_PORT" "$MONGO_DB_NAME" "$MONGO_USER" "$MONGO_PASSWORD" \
            || die "phase_mongo: failed to create SCRAM user for tenant ${TENANT_ID}"

        # Enable auth: rewrite port.env with MONGO_AUTH_ARGS, daemon-reload
        # (needed for the LoadCredential= in the template to be picked up
        # even though it's already there — safer against split states),
        # then restart mongod@ so it comes up with --auth --keyFile.
        _write_mongo_port_env_with_auth
        run_privileged systemctl daemon-reload
        run_privileged systemctl restart "mongod@${TENANT_ID}.service"
        MONGO_URL=$(mongo_build_url_authed "$MONGO_PORT" "$MONGO_DB_NAME" \
            "$MONGO_USER" "$MONGO_PASSWORD")
        mongo_wait_ready "$MONGO_URL" 60 1 \
            || die "mongod@${TENANT_ID} did not answer authed ping after --auth activation"
        log_info "mongo: auth enabled for ${TENANT_ID} (user='${MONGO_USER}', role=dbOwner on '${MONGO_DB_NAME}')"
    else
        # In dry-run, still compute the URL so downstream phases have
        # something coherent to render.
        MONGO_USER="bebop_${TENANT_ID//-/_}"
        MONGO_PASSWORD="dry-run-placeholder"
        MONGO_URL=$(mongo_build_url_authed "$MONGO_PORT" "$MONGO_DB_NAME" \
            "$MONGO_USER" "$MONGO_PASSWORD")
    fi
    log_info "Mongo: db=${MONGO_DB_NAME} on 127.0.0.1:${MONGO_PORT} (rs=rs0, auth=on)"
}

# Rewrite /etc/be-BOP-mongodb/<tid>/port.env with MONGO_AUTH_ARGS enabled.
# Called from phase_mongo (fresh) and migrate-mongo-auth.sh — kept in
# add-tenant.sh so both paths share the exact format.
_write_mongo_port_env_with_auth() {
    local tmp
    tmp=$(mktemp)
    # MONGO_AUTH_ARGS value MUST be double-quoted: systemd EnvironmentFile
    # accepts spaces fine, but bebop-mongo-preflight.sh sources the file
    # via bash `source`, and bash's shell parser treats
    #   KEY=value1 value2
    # as "run 'value2' with KEY=value1". Quoting collapses the whole
    # thing into a single VAR value for both consumers.
    printf 'MONGO_PORT=%s\nMONGO_AUTH_ARGS="--auth --keyFile /run/credentials/mongod@%s.service/keyfile"\n' \
        "$MONGO_PORT" "$TENANT_ID" > "$tmp"
    run_privileged install -m 0640 "$tmp" "/etc/be-BOP-mongodb/${TENANT_ID}/port.env"
    rm -f "$tmp"
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
    # Residual-data cleanup for prior-run leftovers is deliberately NOT
    # done here — `preflight_purge_orphans` at the top of main() runs
    # BEFORE any phase creates legitimate current-tenant state, and it
    # already sweeps /var/lib/private/… via find-orphans. Doing the same
    # check here would (and did, in commit 3618886) wipe the mongod state
    # that phase_mongo just created for the current tenant.
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

# Phase 8b: mail-relay tenant registration (LOCAL ONLY).
#
# Creates the tenant's row in the tooling MongoDB (mail-relay state) and seeds its
# runtimeConfig.smtp so bebop@<tenant> starts with a working SMTP config
# against 127.0.0.1:2525. That's it — this phase touches ZERO upstream
# provider. The tenant can send from day one (relay accepts AUTH and
# logs everything to send_log) whether or not an upstream provider is
# configured.
#
# Upstream domain declaration (see lib/scaleway.sh for the V1 adapter)
# is decoupled from provisioning: a separate systemd-timer sweep scans
# the relay for tenants with upstream_domain_id IS NULL and declares
# them upstream when the operator has provided provider credentials.
# See mail-upstream-sync.sh + tooling-mail-relay-upstream-sync.timer.
#
# Idempotent: skipped if the operator queued a manual --runtime-config
# smtp=... override (BYO or migration), or if the tenant already has a
# relay row (reapply / reactivate — password rotation is an explicit
# ops action via mail-relay-ctl reset-tenant).
phase_mail_relay() {
    log_info "phase 8b: mail-relay local registration (upstream decoupled)..."

    local entry
    for entry in "${RUNTIME_CONFIG_OVERRIDES[@]+"${RUNTIME_CONFIG_OVERRIDES[@]}"}"; do
        if [[ "$entry" == *:smtp=* ]]; then
            log_info "mail-relay: operator passed --runtime-config smtp=... — skipping auto setup"
            return 0
        fi
    done

    if ! command -v mail-relay-ctl.sh >/dev/null 2>&1; then
        log_warn "mail-relay: mail-relay-ctl.sh not on PATH — skipping (relay not installed?)"
        return 0
    fi

    # Behaviour depends on DECISION_PATH:
    #   fresh     — row is expected absent (purge should have cleaned it).
    #               If it survived: integrity failure surfacing a bug in
    #               orphan cleanup. We log_warn and recover by rotating
    #               via `reset-tenant`, so the operator isn't blocked. We
    #               do NOT register an undo for the pre-existing row (we
    #               didn't create it).
    #   reapply/reactivate — row is expected present. `create` failing
    #               with "already exists" is normal; we skip the seed
    #               entirely because the tenant is already using its
    #               current runtimeConfig.smtp — rotating would
    #               invalidate a live credential.
    # Any OTHER failure of `create` (mongod@tooling unreachable, mongosh
    # missing, bcrypt broken, …) is a real bug: die with the captured
    # stderr instead of silently absorbing it, which would leave
    # runtimeConfig.smtp = null.
    local relay_creds password err_output tmp_err
    tmp_err=$(mktemp)
    local created_by_us=false
    if relay_creds=$(mail-relay-ctl.sh create "$TENANT_ID" 2>"$tmp_err"); then
        rm -f "$tmp_err"
        password=$(printf '%s' "$relay_creds" | cut -f2)
        [[ -z "$password" ]] && die "mail-relay: create returned empty password for '${TENANT_ID}' (unexpected)"
        created_by_us=true
        txn_register_undo "mail-relay row for ${TENANT_ID}" \
            "mail-relay-ctl.sh delete '${TENANT_ID}' 2>/dev/null || true"
    else
        err_output=$(cat "$tmp_err" 2>/dev/null || true)
        rm -f "$tmp_err"
        if [[ "$err_output" != *"already exists"* ]]; then
            die "mail-relay: mail-relay-ctl create failed for '${TENANT_ID}': ${err_output:-<no stderr>}"
        fi
        case "${DECISION_PATH:-fresh}" in
            reapply|reactivate)
                log_info "mail-relay: '${TENANT_ID}' already has a relay row — preserving current credential (reapply)"
                return 0
                ;;
            fresh|*)
                log_warn "mail-relay: integrity — '${TENANT_ID}' relay row survived purge (orphan cleanup bug?). Recovering via reset-tenant."
                local reset_out reset_err
                reset_err=$(mktemp)
                if reset_out=$(mail-relay-ctl.sh reset-tenant "$TENANT_ID" 2>"$reset_err"); then
                    rm -f "$reset_err"
                    password=$(printf '%s' "$reset_out" | cut -f2)
                    [[ -z "$password" ]] && die "mail-relay: reset-tenant returned empty password for '${TENANT_ID}' (unexpected)"
                else
                    err_output=$(cat "$reset_err" 2>/dev/null || true)
                    rm -f "$reset_err"
                    die "mail-relay: reset-tenant failed for '${TENANT_ID}': ${err_output:-<no stderr>}"
                fi
                ;;
        esac
    fi

    # Compose SMTP config and append to the generic runtimeConfig
    # overrides array. apply_runtime_config_overrides() at
    # phase_bebop_service writes it via mongo_runtime_config_upsert
    # (commit 8242d54's generic mechanism — nothing smtp-specific).
    local subdomain="${TENANT_ID}.${BEBOP_DNS_ZONE}"
    local smtp_value
    smtp_value=$(jq -nc \
        --arg host "127.0.0.1" \
        --argjson port 2525 \
        --arg user "$TENANT_ID" \
        --arg pass "$password" \
        --arg from "noreply@${subdomain}" \
        --argjson fake false \
        '{host: $host, port: $port, user: $user, password: $pass, from: $from, fake: $fake}')
    RUNTIME_CONFIG_OVERRIDES+=("false:smtp=${smtp_value}")
    log_info "mail-relay: '${TENANT_ID}' relay row + runtimeConfig.smtp queued (upstream declaration handled off-band, see main())"
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
    # Atomic write: install then rename over the target. If a reapply is
    # interrupted mid-run, the live config.env stays intact until the mv -T
    # succeeds. Rename is atomic within the same filesystem.
    local stage="${target}.new"
    run_privileged install -m 0640 "$tmp" "$stage"
    run_privileged mv -T "$stage" "$target"
    rm -f "$tmp"
    # rm-undo is destructive; register it ONLY on fresh creation. On reapply
    # the tenant is live — a rollback that rm's config.env would 502 it.
    if [[ "${DECISION_PATH:-fresh}" == "fresh" ]]; then
        txn_register_undo "config.env ${TENANT_ID}" \
            "run_privileged rm -f '${target}'"
    fi
    log_info "config.env installed (mode 0640)"
}

# Phase 10: TLS cert (per-tenant SAN, DNS-01 via provider-agnostic hook)
#
# We use certbot --manual + our own auth/cleanup hooks instead of the
# per-provider certbot-dns-* plugins. Those plugins typically require
# broad API scopes for zone auto-discovery; our hooks already know the
# zone from secrets.env (BEBOP_DNS_ZONE) and delegate the actual DNS
# mutation to lib/dns_provider.sh, so a narrowly-scoped token per
# provider suffices.
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
# Wraps `certbot` with two guarantees the raw invocation lacks:
#   1. --server injection when LE_STAGING=true, so retries against the
#      staging endpoint don't burn the production rate-limit window.
#   2. stderr+stdout captured; on non-zero exit we extract the actionable
#      ACME failure (rateLimited, badNonce, DNS problem, etc.) instead of
#      letting certbot's misleading "AttributeError: can't set attribute"
#      cover the real cause (upstream josepy+py3.11 bug in certbot 2.1.0).
_certbot_run() {
    local -a args=("$@")
    if [[ "$LE_STAGING" == "true" ]]; then
        args=("${args[@]}" --server "https://acme-staging-v02.api.letsencrypt.org/directory")
        log_info "certbot: using Let's Encrypt STAGING (certs are untrusted by browsers)"
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run: certbot ${args[*]}"
        return 0
    fi
    # Serialize concurrent certbot invocations across parallel
    # add-tenant.sh calls. certbot itself takes an exclusive lock on
    # /var/log/letsencrypt/.certbot.lock — when the second instance
    # can't get it, certbot exits with a cryptic error. Our own flock
    # here queues the invocations cleanly instead: acquire → run →
    # release. Timeout large enough for a DNS-01 SAN cert issuance
    # (typically 30-60s per tenant) times a modest queue depth.
    : "${CERTBOT_LOCK_PATH:=/var/lib/be-BOP/.certbot.lock}"
    : "${CERTBOT_LOCK_TIMEOUT_SECONDS:=300}"
    run_privileged install -d -m 0755 /var/lib/be-BOP
    run_privileged touch "$CERTBOT_LOCK_PATH"
    local out rc=0
    out=$(run_privileged flock -x -w "$CERTBOT_LOCK_TIMEOUT_SECONDS" \
        "$CERTBOT_LOCK_PATH" \
        certbot "${args[@]}" 2>&1) || rc=$?
    if (( rc == 0 )); then
        # Success — echo the useful lines (usually the "Certificate is
        # saved at:" block) so ops keeps visibility.
        printf '%s\n' "$out" | grep -E '^(Successfully|Certificate is saved|Key is saved|This certificate expires)' >&2 || true
        return 0
    fi
    # Failure — surface the actionable ACME error FIRST, then the raw
    # log tail for context. certbot 2.1.0 swallows the real message
    # via a josepy+py3.11 bug (only "AttributeError: can't set
    # attribute" leaks to stderr), so the ACME error line is
    # essentially always in /var/log/letsencrypt/letsencrypt.log, not
    # in `$out`. We grep the log first, fall back to `$out` if the
    # file isn't readable.
    local log_tail
    log_tail=$(run_privileged tail -n 30 /var/log/letsencrypt/letsencrypt.log 2>/dev/null || true)
    local haystack="${log_tail}
${out}"
    local acme_line
    acme_line=$(printf '%s\n' "$haystack" | grep -oE 'urn:ietf:params:acme:error:[^" ]+' | head -n1 || true)
    if [[ -n "$acme_line" ]]; then
        log_error "certbot: ACME error → ${acme_line}"
    fi
    # Rate-limit specific advice: pull the retry-after date if present.
    if [[ "$haystack" == *rateLimited* ]]; then
        local retry
        retry=$(printf '%s\n' "$haystack" \
            | grep -oE 'retry after [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ UTC' \
            | head -n1 || true)
        log_error "certbot: Let's Encrypt rate-limited (max 5 duplicate certs / 168h on the SAME set of identifiers)."
        [[ -n "$retry" ]] && log_error "certbot: next retry window opens at ${retry}."
        log_error "certbot: for repeated test provisionings, re-run add-tenant.sh with --staging (or set BEBOP_LE_STAGING=true in secrets.env)."
    fi
    # Full letsencrypt.log tail last — the actionable message above stays
    # visible above the 30-line dump instead of being buried under it.
    if [[ -n "$log_tail" ]]; then
        log_error "certbot: last 30 lines of /var/log/letsencrypt/letsencrypt.log:"
        printf '%s\n' "$log_tail" | while IFS= read -r line; do
            log_error "  ${line}"
        done
    fi
    return "$rc"
}

_issue_cert_http01() {
    local cert_name="$1" domain="$2" email="$3"
    if run_privileged test -d "/etc/letsencrypt/live/${cert_name}"; then
        log_info "cert ${cert_name} already issued — skipping certbot"
        return 0
    fi
    _certbot_run \
        certonly \
        --webroot --webroot-path /var/lib/letsencrypt \
        --non-interactive --agree-tos \
        --email "$email" \
        --cert-name "$cert_name" \
        -d "$domain"
    txn_register_undo "Let's Encrypt cert ${cert_name}" \
        "run_privileged certbot delete --non-interactive --cert-name '${cert_name}' 2>/dev/null || true"
}

# _issue_cert_dns01 <cert_name> <domain> <acme_email> <hooks_dir>
# Single-domain DNS-01 via our provider-agnostic hook (the same hook the SAN cert uses).
_issue_cert_dns01() {
    local cert_name="$1" domain="$2" email="$3" hooks_dir="$4"
    if run_privileged test -d "/etc/letsencrypt/live/${cert_name}"; then
        log_info "cert ${cert_name} already issued — skipping certbot"
        return 0
    fi
    _certbot_run \
        certonly \
        --manual \
        --preferred-challenges dns-01 \
        --manual-auth-hook "${hooks_dir}/certbot-dns-auth.sh" \
        --manual-cleanup-hook "${hooks_dir}/certbot-dns-cleanup.sh" \
        --non-interactive --agree-tos \
        --email "$email" \
        --cert-name "$cert_name" \
        -d "$domain"
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
    _certbot_run \
        certonly \
        --manual \
        --preferred-challenges dns-01 \
        --manual-auth-hook "${hooks_dir}/certbot-dns-auth.sh" \
        --manual-cleanup-hook "${hooks_dir}/certbot-dns-cleanup.sh" \
        --non-interactive --agree-tos \
        --email "$email" \
        --cert-name "$cert_name" \
        -d "$domain" \
        -d "$s3_domain"
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
    # Atomic write: rename over the destination in the same filesystem so a
    # reapply interrupted mid-write can't leave the live vhost broken.
    local stage="${available}.new"
    run_privileged install -m 0644 "$tmp" "$stage"
    run_privileged mv -T "$stage" "$available"
    rm -f "$tmp"
    run_privileged ln -sfn "$available" "$enabled"
    # rm-undo is destructive; register it ONLY on fresh creation. A rollback
    # of a live tenant that rm's its vhost yields immediate 502/404.
    if [[ "${DECISION_PATH:-fresh}" == "fresh" ]]; then
        txn_register_undo "nginx vhost bebop-${TENANT_ID}" \
            "run_privileged rm -f '${enabled}' '${available}' && run_privileged systemctl reload nginx"
    fi
    if [[ "$DRY_RUN" != "true" ]]; then
        # Quarantine any pre-existing broken vhost (cert missing or
        # syntax invalid) before `nginx -t` — otherwise a completely
        # valid tenant deploy fails just because ANOTHER vhost is
        # broken. Observed 2026-07 when find-orphans deleted the
        # bebop-deploy-api cert; every subsequent add-tenant.sh rolled
        # back at phase 11.
        nginx_quarantine_broken_vhosts
        if ! run_privileged nginx -t; then
            die "nginx -t failed after writing vhost — check /etc/nginx/sites-available/bebop-${TENANT_ID}.conf"
        fi
        run_privileged systemctl reload nginx
    fi
}

# apply_smtp_prefill() intentionally removed. The host-wide SMTP_* env
# vars in secrets.env belong to lib/notify.sh (tooling-side alerts) and
# must never be replicated into a tenant's runtimeConfig.smtp — that
# would surface ops-side mail credentials to a merchant and defeat the
# whole per-tenant isolation of the fake-SMTP design. A tenant's
# runtimeConfig.smtp is now populated ONLY by phase_mail_relay, which
# generates a fresh per-tenant password via mail-relay-ctl.sh and
# points at 127.0.0.1:2525 (the local fake SMTP).

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
    # Use the authed URI ($MONGO_URL) set by phase_mongo, not the raw
    # port — after phase_mongo enables --auth on mongod@, an unauth port
    # connect returns "not authorized" on runtimeConfig.updateOne.
    if ! mongo_wait_ready "$MONGO_URL" 60 1; then
        die "runtime-config: mongod@${TENANT_ID} not ready"
    fi
    local entry lock rest key value trimmed
    for entry in "${RUNTIME_CONFIG_OVERRIDES[@]}"; do
        lock="${entry%%:*}"
        rest="${entry#*:}"
        key="${rest%%=*}"
        value="${rest#*=}"
        # Auto-detect JSON object/array literals so nested runtimeConfig
        # entries (like `smtp`, which be-BOP reads via Object.assign and
        # therefore MUST be a real object) are stored parsed rather than
        # stringified. Scalar strings/numbers go through the string
        # variant unchanged — backward compatible with
        # `--runtime-config websiteTitle="ACME"`.
        trimmed="${value#"${value%%[![:space:]]*}"}"
        if [[ "$trimmed" == "{"* || "$trimmed" == "["* ]] \
                && printf '%s' "$value" | jq -e . >/dev/null 2>&1; then
            mongo_runtime_config_upsert_obj "$MONGO_URL" "$MONGO_DB_NAME" "$key" "$value" "$lock" \
                || die "runtime-config: upsert (object) failed for ${key}"
        else
            mongo_runtime_config_upsert "$MONGO_URL" "$MONGO_DB_NAME" "$key" "$value" "$lock" \
                || die "runtime-config: upsert failed for ${key}"
        fi
    done
}

# Phase 12: bebop service
phase_bebop_service() {
    log_info "phase 12: bebop@${TENANT_ID}.service..."
    # NB: the host-wide SMTP_HOST/USER/PASSWORD in secrets.env are ONLY
    # for lib/notify.sh's ops alerts (bug/incident notifications from the
    # tooling itself). They MUST NEVER be replicated into a tenant's
    # runtimeConfig.smtp — a tenant's smtp creds are generated on the fly
    # by phase_mail_relay (mail-relay-ctl.sh create → unique password per
    # tenant, pointing at the local fake SMTP on 127.0.0.1:2525, which
    # then relays to the configured upstream provider).
    apply_runtime_config_overrides
    # Register the undo BEFORE the enable — if `systemctl enable --now` fails
    # (e.g. ExecStartPre error), `set -e` triggers exit immediately and the
    # rollback loop must know about the unit to disable it. Registering after
    # the enable would leave the failed unit enabled and stuck in a
    # Restart=on-failure loop referencing files that phase-earlier rollbacks
    # have already removed.
    txn_register_undo "bebop@${TENANT_ID}.service" \
        "run_privileged systemctl disable --now 'bebop@${TENANT_ID}.service' 2>/dev/null || true; \
         run_privileged rm -f '/etc/systemd/system/multi-user.target.wants/bebop@${TENANT_ID}.service' 2>/dev/null || true; \
         run_privileged systemctl daemon-reload 2>/dev/null || true"
    run_privileged systemctl enable --now "bebop@${TENANT_ID}.service"
}

# Phase 13: HTTP healthcheck
#
# For external-domain tenants, we bypass the VDS's local resolver via
# `curl --resolve` and direct curl at the host IPs we already validated
# against the authoritative NS in phase 3. Without this, the healthcheck
# routinely fails because the operator just set their public DNS and the
# system resolver still has a negative cache — even though the zone IS
# correctly published (proved by the auth-NS check). For internal tenants
# we keep using the system resolver (propagation on our own zone is
# usually fast enough).
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
    case "${DECISION_PATH:-fresh}" in
        fresh)
            # The row already exists (status='provisioning', inserted
            # by phase_derive_identifiers). Flip it to 'active' and
            # stamp the resolved version. Both mutations under a single
            # brief lock — no port reallocation, no DNS/cert side
            # effects here.
            _finalise_registry_row() {
                registry_set_field "$TENANT_ID" bebop_version "$RESOLVED_VERSION"
                registry_set_status "$TENANT_ID" active
            }
            registry_lock_scope _finalise_registry_row \
                || die "phase 14: failed to finalise registry row for ${TENANT_ID}"
            ;;
        reactivate)
            registry_lock_scope registry_set_status "$TENANT_ID" active
            ;;
        reapply)
            # Already active; refresh version if it changed.
            registry_lock_scope registry_set_field "$TENANT_ID" bebop_version "$RESOLVED_VERSION"
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
        # phoenixd seed + HTTP password control the merchant's Lightning wallet.
        # Print them ONLY if stdout is an interactive TTY. Otherwise (piped, tee,
        # captured by a daemon like tenant-api) write them to a root-owned
        # 0600 file and print only its path — prevents leak into install.log,
        # journal captures, notification bodies, etc.
        if [[ -t 1 ]]; then
            cat <<EOF
  ==== TRANSMIT TO MERCHANT (sensitive — handle carefully) ====
  phoenixd HTTP password:   ${PHOENIXD_HTTP_PASSWORD}
  phoenixd seed (hex):      ${PHOENIXD_SEED_HEX:-(seed.dat not readable)}

  These credentials control the merchant's Lightning wallet. Store them in
  the merchant's password manager and back the seed up off-host (encrypted).

EOF
        else
            local secrets_dir=/root/bebop-tenant-secrets
            local secrets_file="${secrets_dir}/${TENANT_ID}.txt"
            run_privileged install -d -m 0700 "$secrets_dir"
            run_privileged tee "$secrets_file" >/dev/null <<EOF
tenant: ${TENANT_ID}
created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
phoenixd HTTP password: ${PHOENIXD_HTTP_PASSWORD}
phoenixd seed (hex): ${PHOENIXD_SEED_HEX:-(seed.dat not readable)}
EOF
            run_privileged chmod 0600 "$secrets_file"
            cat <<EOF
  ==== TRANSMIT TO MERCHANT (sensitive) ====
  stdout is not a TTY — secrets written to: ${secrets_file} (mode 0600, root)
  Copy them off-host to the merchant's password manager, then delete the file.

EOF
        fi
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
    if [[ "$ENABLE_MAIL_RELAY" == "true" ]]; then
        phase_mail_relay
    else
        log_info "phase 8b: mail-relay disabled (host default or --no-mail-relay) — skipping"
    fi
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
    spawn_upstream_sync
    phase_summary
}

# Fire-and-forget: kick a detached systemd-run transient unit that runs
# the upstream sync script (5 attempts × 60 s) in the background. The
# main deploy critical path — including the API endpoint of
# tenant-api.py — returns as soon as systemd-run has scheduled the
# unit (sub-second). Nothing here waits on Scaleway's async validation.
#
# Skipped when the upstream provider isn't configured (the retry timer
# has the same behavior — a no-op sweep). If systemd-run isn't
# available for whatever reason, we log a WARN and let the 15-min timer
# take the tenant on its next tick — never fatal.
spawn_upstream_sync() {
    if ! mail_upstream_is_configured || [[ -z "${BEBOP_DNS_ZONE:-}" ]]; then
        log_info "upstream provider not configured — skipping background Scaleway sync (timer 15 min stays as safety net)"
        return 0
    fi
    if ! command -v systemd-run >/dev/null 2>&1; then
        log_warn "systemd-run not available — skipping background Scaleway sync spawn; timer 15 min will retry"
        return 0
    fi
    local sync_bin="/usr/local/bin/mail-relay-upstream-sync.sh"
    if [[ ! -x "$sync_bin" ]]; then
        log_warn "background sync binary '${sync_bin}' not found — timer 15 min will retry"
        return 0
    fi
    # --collect: systemd garbage-collects the transient unit after exit.
    # Unique unit name per tenant so concurrent onboardings don't clash
    # and an operator can inspect one at a time via `systemctl status`.
    local unit="tooling-mail-relay-upstream-sync-${TENANT_ID}"
    if run_privileged systemd-run --collect \
            --unit="$unit" \
            --description="Scaleway TEM sync for ${TENANT_ID} (5x60s)" \
            "$sync_bin" "$TENANT_ID" >/dev/null 2>&1; then
        log_info "background Scaleway sync spawned: systemd-run unit '${unit}' (journalctl -u ${unit} to follow, 5 attempts × 60 s)"
    else
        log_warn "failed to spawn background sync unit '${unit}' — timer 15 min will retry"
    fi
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
    # Preserve the existing MONGODB_URL from config.env — for migrated /
    # new tenants it carries the SCRAM user:password. Fallback to unauth
    # URL only if config.env doesn't declare one (shouldn't happen on
    # reactivate, safety net).
    MONGO_URL=""
    if run_privileged test -f "/etc/be-BOP/${TENANT_ID}/config.env"; then
        MONGO_URL=$(run_privileged grep -oP '^MONGODB_URL=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
    fi
    [[ -z "$MONGO_URL" ]] && MONGO_URL=$(mongo_build_url "$MONGO_PORT" "$MONGO_DB_NAME")
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
    phase_mail_relay       # idempotent: no-op if the tenant already has a relay row
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
    MONGO_URL=""
    # Re-derive existing Garage creds + phoenixd password from current config.env
    # AND preserve the MONGODB_URL (with SCRAM creds for auth-enabled tenants).
    if run_privileged test -f "/etc/be-BOP/${TENANT_ID}/config.env"; then
        MONGO_URL=$(run_privileged grep -oP '^MONGODB_URL=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
        GARAGE_KEY_ID=$(run_privileged grep -oP '^S3_KEY_ID=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
        GARAGE_KEY_SECRET=$(run_privileged grep -oP '^S3_KEY_SECRET=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
        PHOENIXD_HTTP_PASSWORD=$(run_privileged grep -oP '^PHOENIXD_HTTP_PASSWORD=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
    fi
    [[ -z "$MONGO_URL" ]] && MONGO_URL=$(mongo_build_url "$MONGO_PORT" "$MONGO_DB_NAME")
    if [[ "$BEBOP_VERSION" != "latest" || -z "$(release_get_current_tag "$TENANT_ID")" ]]; then
        phase_release
    else
        RESOLVED_VERSION=$(release_get_current_tag "$TENANT_ID")
    fi
    phase_config_env
    phase_certificate
    phase_nginx
    phase_mail_relay       # idempotent: no-op if the tenant already has a relay row
    # apply_smtp_prefill removed on purpose — never leak host-wide ops
    # SMTP creds into a tenant's runtimeConfig. See phase_bebop_service.
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

# Fill unset knobs (3-state: "" from CLI = not overridden) from
# deploy-default.json.defaults, falling back to hardcoded "true" per
# knob when the file is missing or the key is absent. Called after all
# arg parsing, before phase execution.
apply_deploy_defaults() {
    local file="$DEPLOY_DEFAULT_FILE"
    local phoenixd_def=true local_s3_def=true mail_relay_def=true
    if [[ -f "$file" ]] && jq -e . "$file" >/dev/null 2>&1; then
        phoenixd_def=$(jq -r '.defaults.phoenixd // true' "$file")
        local_s3_def=$(jq -r '.defaults.local_s3 // true' "$file")
        mail_relay_def=$(jq -r '.defaults.mail_relay // true' "$file")
    fi
    [[ -z "$ENABLE_PHOENIXD" ]] && ENABLE_PHOENIXD="$phoenixd_def"
    [[ -z "$ENABLE_MAIL_RELAY" ]] && ENABLE_MAIL_RELAY="$mail_relay_def"
    if [[ -z "$NO_LOCAL_S3" ]]; then
        # NO_LOCAL_S3 is the INVERSE of the LOCAL_S3 default — historical
        # naming (--no-local-s3 opts out of the default-on behaviour).
        if [[ "$local_s3_def" == "true" ]]; then
            NO_LOCAL_S3=false
        else
            NO_LOCAL_S3=true
        fi
    fi
    log_debug "deploy defaults resolved: phoenixd=${ENABLE_PHOENIXD} local_s3=$(if [[ "$NO_LOCAL_S3" == "false" ]]; then echo true; else echo false; fi) mail_relay=${ENABLE_MAIL_RELAY}"
}

# Load a per-source profile from deploy-default.json.profiles[<name>] and
# PREPEND its runtimeConfig entries to RUNTIME_CONFIG_OVERRIDES so that any
# --runtime-config[-locked] entries the CLI already parsed win on same-key
# collisions (mongo upsert = last-write wins per key).
apply_profile() {
    [[ -z "$PROFILE" ]] && return 0
    # Refuse convention-comment keys — those are shown in the template as
    # documentation and should never match a real webhook path. Requires
    # the operator to actually rename the example before use.
    if [[ "$PROFILE" == '$'* || "$PROFILE" == _example* ]]; then
        die "profile '${PROFILE}' looks like a template placeholder (\$-prefixed or _example*) — rename to a real source domain in ${DEPLOY_DEFAULT_FILE}"
    fi
    local file="$DEPLOY_DEFAULT_FILE"
    if [[ ! -f "$file" ]] || ! jq -e . "$file" >/dev/null 2>&1; then
        die "--profile '${PROFILE}' requested but ${file} is missing or invalid JSON"
    fi
    if ! jq -e --arg p "$PROFILE" '.profiles | has($p)' "$file" >/dev/null; then
        die "profile '${PROFILE}' not defined in ${file}. Available: $(jq -r '.profiles | keys | map(select(startswith("$") | not) | select(startswith("_example") | not)) | join(", ")' "$file")"
    fi
    local -a profile_entries=()
    local key value
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        profile_entries+=("true:${key}=${value}")
    done < <(jq -r --arg p "$PROFILE" '.profiles[$p].locked // {} | to_entries[] | "\(.key)=\(.value)"' "$file")
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        profile_entries+=("false:${key}=${value}")
    done < <(jq -r --arg p "$PROFILE" '.profiles[$p].unlocked // {} | to_entries[] | "\(.key)=\(.value)"' "$file")
    if (( ${#profile_entries[@]} == 0 )); then
        log_warn "profile '${PROFILE}' defined but has no runtimeConfig entries"
        return 0
    fi
    RUNTIME_CONFIG_OVERRIDES=("${profile_entries[@]}" "${RUNTIME_CONFIG_OVERRIDES[@]}")
    log_info "profile '${PROFILE}' applied: ${#profile_entries[@]} runtimeConfig entries"
}

main() {
    require_privileges

    if [[ ! -f "$SECRETS_FILE" ]]; then
        die "secrets file not found: ${SECRETS_FILE}"
    fi
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"

    # Deploy defaults + per-source profile — non-secret ops config,
    # parsed from JSON (no shell source). apply_deploy_defaults
    # tolerates a missing file (hardcoded "true" fallbacks) so hosts
    # provisioned before this feature keep the pre-refactor behaviour.
    # apply_profile is a no-op when $PROFILE is empty.
    apply_deploy_defaults
    apply_profile

    registry_init
    # The registry lock is NO LONGER held for the full duration of
    # main(). It's now acquired only around the specific mutations
    # (port allocation + placeholder row insert in phase_derive_identifiers,
    # final status flip in phase_kuma_and_registry, reactivate/reapply
    # single-field updates). This keeps concurrent add-tenant.sh calls
    # from serialising on DNS / cert / mongo / phoenixd / kuma work
    # (~55 s) — the pre-fix behavior that made 3 API orders in <30s
    # blow past the flock 30s timeout on the third.
    # `on_script_exit` still calls registry_unlock defensively — it
    # no-ops when we don't hold the fd, so it's safe on every path.

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

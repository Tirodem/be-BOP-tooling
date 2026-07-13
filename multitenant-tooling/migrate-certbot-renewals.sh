#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# migrate-certbot-renewals.sh — reconcile /etc/letsencrypt/renewal/*.conf
# against the current be-BOP-tooling state (active tenants + host
# services), and act automatically per cert.
#
# WHY THIS EXISTS
#   Historically the tooling emitted every cert via `certbot --manual` +
#   DNS-01 hooks. That path is (a) provider-coupled (dies when the fleet's
#   canonical DNS provider changes), and (b) unnecessary for non-wildcard
#   certs whose vhost is already served by nginx — HTTP-01 webroot then
#   works with zero DNS API credentials.
#
#   Some certs pre-date the current fleet layout and belong to services
#   that no longer live on this host. Renewing them would require creds
#   we've decommissioned; keeping them just makes `certbot renew` fail
#   every night. Delete is the right answer.
#
# WHAT IT DOES  (per cert reported by `certbot certificates`)
#   ALL SANs live → migrate the .conf to HTTP-01 webroot (drops legacy
#                   DNS hook + pref_challs). Idempotent.
#   NO  SAN  live → cert is orphaned; `certbot delete` (destructive but
#                   safe: we refuse to delete a cert whose live/ path is
#                   still referenced by any nginx vhost).
#   SOME live     → warn + skip. Needs manual triage; we won't guess.
#
# LIVE-DOMAIN SOURCES
#   1. tenants.tsv (status=active), each row yields main domain + s3.<main>
#      (mirrors how add-tenant.sh always issues certs with both SANs).
#   2. secrets.env :
#        BEBOP_DEPLOY_API_HOSTNAME
#        KUMA_PUBLIC_HOSTNAME
#        NETDATA_PUBLIC_HOSTNAME
#
# MODES
#   (default)    execute the plan (both migrate + delete)
#   --dry-run    print the plan, touch nothing
#   --no-delete  execute migrations, skip deletes (opt-out for destructive)

set -eEuo pipefail

readonly SCRIPT_NAME="migrate-certbot-renewals"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "${SCRIPT_NAME}: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"

: "${SECRETS_FILE:=/etc/be-BOP-tooling/secrets.env}"
: "${LE_RENEWAL_DIR:=/etc/letsencrypt/renewal}"
: "${LE_LIVE_DIR:=/etc/letsencrypt/live}"
: "${LE_WEBROOT_PATH:=/var/lib/letsencrypt}"

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

DRY_RUN=false
NO_DELETE=false

usage() {
    cat <<EOF
${SCRIPT_NAME}.sh — reconcile certbot renewals with current tenant registry
and host services. Live certs get switched to HTTP-01 webroot; orphaned
certs get deleted.

Usage:
  sudo ${SCRIPT_NAME}.sh [options]

Options:
  --dry-run     print the plan, do not touch anything
  --no-delete   execute migrations, skip 'certbot delete' for orphans
  -h, --help
EOF
}

while (( $# )); do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --no-delete) NO_DELETE=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

require_privileges

# --- Build the live-domain set -------------------------------------------

# Load host-service hostnames from secrets.env (silent if unset).
set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

declare -A LIVE

add_live() {
    local d="$1"
    [[ -z "$d" ]] && return 0
    LIVE["$d"]=1
}

# Tenants: column 2 = domain, column 11 = status. active only. Each tenant
# contributes both the main domain and s3.<main> because add-tenant.sh
# always issues the cert with both SANs (main vhost + s3 subdomain for
# object-storage endpoint).
if run_privileged test -f "$REGISTRY_PATH"; then
    while IFS=$'\t' read -r _tid dom _bport _phx _mport _mdb _gbucket _gkey _bver _created status _external; do
        [[ "$status" != "active" ]] && continue
        [[ -z "$dom" ]] && continue
        add_live "$dom"
        add_live "s3.${dom}"
    done < <(run_privileged tail -n +2 "$REGISTRY_PATH")
fi

# Host services.
add_live "${BEBOP_DEPLOY_API_HOSTNAME:-}"
add_live "${KUMA_PUBLIC_HOSTNAME:-}"
add_live "${NETDATA_PUBLIC_HOSTNAME:-}"

log_info "live domain set (${#LIVE[@]} entries): $(printf '%s ' "${!LIVE[@]}" | sed 's/ $//')"

# --- Enumerate certs and their SANs --------------------------------------

# `certbot certificates` output shape:
#   Certificate Name: <name>
#     Domains: a.b c.d
#     Expiry Date: ...
# We fold each (name, SANs) pair into two parallel arrays.
CERT_NAMES=()
CERT_SANS=()   # SANs joined by space

current=""
current_sans=""
while IFS= read -r line; do
    case "$line" in
        *"Certificate Name:"*)
            if [[ -n "$current" ]]; then
                CERT_NAMES+=("$current")
                CERT_SANS+=("$current_sans")
            fi
            current="${line##* }"
            current_sans=""
            ;;
        *"Domains:"*)
            current_sans="${line#*Domains: }"
            ;;
    esac
done < <(run_privileged certbot certificates 2>/dev/null)
if [[ -n "$current" ]]; then
    CERT_NAMES+=("$current")
    CERT_SANS+=("$current_sans")
fi

if (( ${#CERT_NAMES[@]} == 0 )); then
    log_info "no certs reported by certbot; nothing to reconcile"
    exit 0
fi

# --- Classify each cert --------------------------------------------------

# Returns "migrate" | "delete" | "skip:mixed" | "skip:no-conf".
classify_cert() {
    local name="$1" sans="$2"
    local conf="${LE_RENEWAL_DIR}/${name}.conf"
    if ! run_privileged test -f "$conf"; then
        printf 'skip:no-conf'
        return 0
    fi
    local live_hits=0 dead_hits=0 san
    for san in $sans; do
        if [[ -n "${LIVE[$san]:-}" ]]; then
            (( ++live_hits )) || true
        else
            (( ++dead_hits )) || true
        fi
    done
    if (( live_hits > 0 && dead_hits == 0 )); then
        printf 'migrate'
    elif (( live_hits == 0 && dead_hits > 0 )); then
        printf 'delete'
    else
        printf 'skip:mixed'
    fi
}

# --- Migration to webroot -----------------------------------------------

# Rewrite the .conf to authenticator=webroot / webroot_path=<LE_WEBROOT_PATH>,
# stripping any legacy manual-hook / pref_challs lines. Idempotent: a .conf
# already in webroot mode ends up byte-identical after the awk pass.
migrate_conf_to_webroot() {
    local conf="$1"
    local tmp
    tmp="$(mktemp)"
    run_privileged awk -v webroot="$LE_WEBROOT_PATH" '
        /^\[renewalparams\]/ {
            print
            print "authenticator = webroot"
            print "webroot_path = " webroot
            next
        }
        /^pref_challs[[:space:]]*=/         { next }
        /^authenticator[[:space:]]*=/       { next }
        /^manual_auth_hook[[:space:]]*=/    { next }
        /^manual_cleanup_hook[[:space:]]*=/ { next }
        /^webroot_path[[:space:]]*=/        { next }
        { print }
    ' "$conf" > "$tmp"
    run_privileged install -m 0644 "$tmp" "$conf"
    rm -f "$tmp"
}

# --- Orphan deletion safety --------------------------------------------

# Refuse the delete if any nginx vhost still references the cert's live/
# path. Prevents nuking a cert nginx still tries to load at reload —
# catches vhosts that survived tenant removal by accident.
cert_referenced_by_nginx() {
    local name="$1"
    local live_path="${LE_LIVE_DIR}/${name}/"
    run_privileged nginx -T 2>/dev/null | grep -qF "$live_path"
}

# --- Execute the plan --------------------------------------------------

MIGRATED=0
DELETED=0
SKIPPED=0

for i in "${!CERT_NAMES[@]}"; do
    name="${CERT_NAMES[$i]}"
    sans="${CERT_SANS[$i]}"
    action=$(classify_cert "$name" "$sans")

    case "$action" in
        migrate)
            log_info "MIGRATE  ${name} (SANs: ${sans}) → HTTP-01 webroot"
            if [[ "$DRY_RUN" != "true" ]]; then
                migrate_conf_to_webroot "${LE_RENEWAL_DIR}/${name}.conf"
                (( ++MIGRATED )) || true
            fi
            ;;
        delete)
            if [[ "$NO_DELETE" == "true" ]]; then
                log_warn "SKIP (--no-delete)  ${name} (orphan; SANs: ${sans})"
                (( ++SKIPPED )) || true
                continue
            fi
            if cert_referenced_by_nginx "$name"; then
                log_warn "SKIP  ${name} (orphan by registry, BUT nginx still references ${LE_LIVE_DIR}/${name}/ — refusing destructive delete)"
                (( ++SKIPPED )) || true
                continue
            fi
            log_info "DELETE   ${name} (orphan; SANs: ${sans})"
            if [[ "$DRY_RUN" != "true" ]]; then
                if ! run_privileged certbot delete --cert-name "$name" -n; then
                    log_error "certbot delete failed for ${name}"
                else
                    (( ++DELETED )) || true
                fi
            fi
            ;;
        skip:mixed)
            log_warn "SKIP  ${name} (mixed: some SANs live, some dead; SANs=${sans}) — manual triage needed"
            (( ++SKIPPED )) || true
            ;;
        skip:no-conf)
            log_warn "SKIP  ${name} (no renewal .conf found)"
            (( ++SKIPPED )) || true
            ;;
    esac
done

# --- Purge deprecated OVH hook files if lingering on disk --------------

if [[ "$DRY_RUN" != "true" ]]; then
    for f in certbot-ovh-auth.sh certbot-ovh-cleanup.sh; do
        p="/usr/local/share/be-BOP-tooling/hooks/${f}"
        if run_privileged test -f "$p"; then
            run_privileged rm -f "$p"
            log_info "removed deprecated hook ${p}"
        fi
    done
fi

log_info "reconcile complete — migrated=${MIGRATED} deleted=${DELETED} skipped=${SKIPPED}"
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "(dry-run; no filesystem changes)"
else
    log_info "verify with:  sudo certbot renew --dry-run"
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# upgrade-tenant.sh — upgrade a single be-BOP tenant to a new release.
#
# Steps:
#   1. Resolve --version (default: "latest").
#   2. Note the currently-active release tag (for rollback).
#   3. Download + extract + pnpm install the new release.
#   4. Atomically swap the 'current' symlink.
#   5. systemctl restart bebop@<tenant>.service
#   6. HTTP healthcheck on https://<domain>/.
#   7. On healthcheck failure: revert symlink to old tag and restart
#      (unless --no-rollback-on-failure was given), then alert + exit 1.
#   8. Update registry.bebop_version.

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="upgrade-tenant"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "upgrade-tenant: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/release.sh
source "$BEBOP_TOOLING_LIB_DIR/release.sh"
# shellcheck source=lib/healthcheck.sh
source "$BEBOP_TOOLING_LIB_DIR/healthcheck.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"

readonly HEALTHCHECK_RETRIES=15
readonly HEALTHCHECK_INTERVAL=2

# === CLI ================================================================
SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
TENANT_ID=""
VERSION="latest"
ROLLBACK_ON_FAILURE=true
DRY_RUN=false
RUN_NON_INTERACTIVE=false
VERBOSE=false
# Runtime-config overrides applied to runtimeConfig collection right before
# the bebop restart. Stored as "<lock>:<key>=<value>" strings. See
# parse_runtime_config_flag below.
RUNTIME_CONFIG_OVERRIDES=()

parse_runtime_config_flag() {
    local lock="$1" arg="$2"
    if [[ ! "$arg" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
        die "invalid runtime-config '${arg}': expected KEY=VALUE (KEY must match [a-zA-Z_][a-zA-Z0-9_]*)"
    fi
    RUNTIME_CONFIG_OVERRIDES+=("${lock}:${arg}")
}

usage() {
    cat <<EOF
upgrade-tenant.sh — upgrade a single tenant to a new be-BOP release.

Usage:
  upgrade-tenant.sh <tenant_id> [options]

Options:
  --version <tag>             release tag, or "latest" (default)
  --no-rollback-on-failure    do NOT revert the symlink if the healthcheck
                              fails (default: rollback enabled)
  --runtime-config KEY=VALUE
                              upsert {_id:KEY, data:VALUE} into the tenant's
                              runtimeConfig collection just before bebop is
                              restarted. Repeatable. Clears any existing lock
                              on KEY.
  --runtime-config-locked KEY=VALUE
                              same as --runtime-config but also sets lock:true
                              (read-only in the be-BOP UI). Repeatable.
  --secrets-file <path>       override default ${SECRETS_FILE}
  --non-interactive           no prompts; exit if input would be required
  --dry-run                   print actions without executing
  --verbose
  -h, --help

The tenant must currently be 'active' in the registry. Soft-deleted or
archived tenants are refused.
EOF
}

while (( $# )); do
    case "$1" in
        --version)                 VERSION="$2"; shift 2 ;;
        --rollback-on-failure)     ROLLBACK_ON_FAILURE=true; shift ;;
        --no-rollback-on-failure)  ROLLBACK_ON_FAILURE=false; shift ;;
        --runtime-config)          parse_runtime_config_flag "false" "$2"; shift 2 ;;
        --runtime-config-locked)   parse_runtime_config_flag "true"  "$2"; shift 2 ;;
        --secrets-file)            SECRETS_FILE="$2"; shift 2 ;;
        --non-interactive)         RUN_NON_INTERACTIVE=true; shift ;;
        --dry-run)                 DRY_RUN=true; shift ;;
        --verbose)                 VERBOSE=true; shift ;;
        -h|--help)                 usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)
            [[ -n "$TENANT_ID" ]] && die "multiple tenant ids on command line"
            TENANT_ID="$1"; shift
            ;;
    esac
done

[[ -z "$TENANT_ID" ]] && { usage; die "tenant_id is required"; }

BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_TENANT_ID BEBOP_TOOLING_SYSLOG_IDENT
export RUN_NON_INTERACTIVE VERBOSE DRY_RUN

# EXIT-trap operator notification — catches die()-style failures (resolve,
# get_asset_url, cache ensure, restart…) that previously exited silently
# before the healthcheck path could call notify_failure. The healthcheck
# branch sets NOTIFIED=true to avoid duplicate notifications.
NOTIFIED=false
on_upgrade_exit() {
    local rc=$?
    [[ "$NOTIFIED" == "true" ]] && return
    (( rc == 0 )) && return
    # notify_failure auto-appends the per-session ERROR/WARN tail (see
    # lib/log.sh + lib/notify.sh) so the actual cause lands in the body.
    notify_failure \
        "[be-BOP tooling] upgrade ${TENANT_ID} FAILED" \
        "$(printf 'Tenant: %s\nTarget: %s\nExit code: %s\n' \
            "$TENANT_ID" "$VERSION" "$rc")"
}
trap 'on_upgrade_exit' EXIT

# === Main ===============================================================
main() {
    require_privileges

    if [[ ! -f "$SECRETS_FILE" ]]; then
        die "secrets file not found: ${SECRETS_FILE}"
    fi
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"

    registry_init
    local status
    status=$(registry_get_status "$TENANT_ID")
    case "$status" in
        active) ;;
        absent)        die "tenant '${TENANT_ID}' is not in the registry" ;;
        soft-deleted)  die "tenant '${TENANT_ID}' is soft-deleted; reactivate it first ('add-tenant.sh ${TENANT_ID} --reactivate')" ;;
        archived)      die "tenant '${TENANT_ID}' is archived; cannot upgrade" ;;
        *)             die "unexpected status '${status}'" ;;
    esac

    local domain old_tag new_tag
    domain=$(registry_get_field "$TENANT_ID" domain)
    old_tag=$(release_get_current_tag "$TENANT_ID")
    if [[ -z "$old_tag" ]]; then
        die "tenant '${TENANT_ID}' has no current release symlink; run add-tenant.sh first"
    fi
    # Skip GitHub API entirely when the cache already holds the requested
    # version (e.g. when upgrade-all has pre-warmed it). Otherwise resolve
    # "latest" / validate the tag the normal way.
    if [[ "$VERSION" != "latest" ]] && release_cache_has "$VERSION"; then
        new_tag="$VERSION"
        log_debug "cache hit for ${VERSION}; skipping GitHub API resolve"
    else
        new_tag=$(release_resolve_version "$VERSION")
    fi
    # Same-version invocations still proceed when the operator passed
    # --runtime-config overrides — they want the config write + a restart.
    if [[ "$new_tag" == "$old_tag" && ${#RUNTIME_CONFIG_OVERRIDES[@]} -eq 0 ]]; then
        log_info "tenant '${TENANT_ID}' already on ${new_tag} — nothing to do"
        exit 0
    fi

    if [[ "$new_tag" == "$old_tag" ]]; then
        log_info "upgrade: ${TENANT_ID}: version unchanged (${new_tag}), applying ${#RUNTIME_CONFIG_OVERRIDES[@]} runtime-config override(s) + restart"
    else
        log_info "upgrade: ${TENANT_ID}: ${old_tag} → ${new_tag}"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would ensure cache for ${new_tag}, swap symlink, apply ${#RUNTIME_CONFIG_OVERRIDES[@]} runtime-config override(s), restart bebop@${TENANT_ID}, healthcheck"
        exit 0
    fi

    release_cache_ensure "$new_tag"
    release_cache_set_current "$TENANT_ID" "$new_tag"

    if (( ${#RUNTIME_CONFIG_OVERRIDES[@]} > 0 )); then
        local mongo_port mongo_db
        mongo_port=$(registry_get_field "$TENANT_ID" mongo_port)
        mongo_db=$(registry_get_field "$TENANT_ID" mongodb_database)
        [[ -z "$mongo_port" || -z "$mongo_db" ]] \
            && die "runtime-config: registry missing mongo_port / mongodb_database for ${TENANT_ID}"
        log_info "applying ${#RUNTIME_CONFIG_OVERRIDES[@]} runtime-config override(s)..."
        if ! mongo_wait_ready "$mongo_port" 60 1; then
            die "runtime-config: mongod@${TENANT_ID} not ready on port ${mongo_port}"
        fi
        local entry lock rest key value
        for entry in "${RUNTIME_CONFIG_OVERRIDES[@]}"; do
            lock="${entry%%:*}"
            rest="${entry#*:}"
            key="${rest%%=*}"
            value="${rest#*=}"
            mongo_runtime_config_upsert "$mongo_port" "$mongo_db" "$key" "$value" "$lock" \
                || die "runtime-config: upsert failed for ${key}"
        done
    fi

    log_info "restarting bebop@${TENANT_ID}.service..."
    run_privileged systemctl restart "bebop@${TENANT_ID}.service"

    if http_wait_ok "https://${domain}/" "$HEALTHCHECK_RETRIES" "$HEALTHCHECK_INTERVAL"; then
        registry_init
        registry_lock
        # shellcheck disable=SC2064
        trap "registry_unlock" EXIT
        registry_set_field "$TENANT_ID" bebop_version "$new_tag"
        notify_success \
            "[be-BOP tooling] upgrade ${TENANT_ID} OK" \
            "Tenant ${TENANT_ID} upgraded ${old_tag} → ${new_tag}."
        log_info "upgrade OK: ${TENANT_ID} now on ${new_tag}"
        exit 0
    fi

    log_error "healthcheck failed for ${TENANT_ID} after upgrade to ${new_tag}"
    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
        log_warn "rolling back to ${old_tag}..."
        # If the old tag was a legacy per-tenant install (pre-cache refactor)
        # its dir may still exist outside the cache. release_cache_ensure
        # populates it now if missing; release_cache_set_current then swaps.
        release_cache_ensure "$old_tag"
        release_cache_set_current "$TENANT_ID" "$old_tag"
        run_privileged systemctl restart "bebop@${TENANT_ID}.service"
        if http_wait_ok "https://${domain}/" "$HEALTHCHECK_RETRIES" "$HEALTHCHECK_INTERVAL"; then
            log_info "rollback to ${old_tag} succeeded"
        else
            log_error "rollback to ${old_tag} ALSO failed — service is broken"
        fi
    fi
    NOTIFIED=true
    notify_failure \
        "[be-BOP tooling] upgrade ${TENANT_ID} FAILED (healthcheck)" \
        "Tenant ${TENANT_ID} upgrade ${old_tag} → ${new_tag} failed at the post-upgrade healthcheck.
Rollback attempted: ${ROLLBACK_ON_FAILURE}
Inspect runtime: journalctl -u bebop@${TENANT_ID} --since '15 min ago'"
    exit 1
}

main "$@"

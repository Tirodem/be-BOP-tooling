#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# migrate-mongo-auth.sh — enable SCRAM auth on tenants provisioned before
# the auth rollout. Idempotent AND resumable — a tenant already migrated
# is skipped silently, so operators can safely re-run with --all.
#
# Per-tenant, rolling (one at a time to bound the blast radius):
#   1. Detect current auth state via /etc/be-BOP-mongodb/<tid>/port.env.
#      MONGO_AUTH_ARGS non-empty → skip, already done.
#   2. Stop bebop@<tid>.service (downtime starts).
#   3. Ensure mongod@<tid> is up in unauth mode; use the localhost
#      exception to create the SCRAM user (dbOwner scoped to the
#      tenant's DB).
#   4. Rewrite port.env with MONGO_AUTH_ARGS pointing to the LoadCredential
#      keyfile, systemctl daemon-reload + restart mongod@<tid>.
#      mongod now runs with --auth --keyFile active.
#   5. Verify authenticated ping using the freshly-built URI.
#   6. Rewrite /etc/be-BOP/<tid>/config.env: replace unauth MONGODB_URL
#      with the authenticated URI. Uses .new + mv -T for atomicity
#      (same pattern as add-tenant.sh phase_config_env).
#   7. Start bebop@<tid>.service (downtime ends, ~30-60s).
#
# On any failure, tries to leave the tenant on the OLD state (bebop@
# restarted, mongod@ back to unauth if we already flipped it) so the
# operator can investigate without a stuck tenant.

set -eEuo pipefail

readonly SCRIPT_NAME="migrate-mongo-auth"
readonly SECRETS_FILE=/etc/be-BOP-tooling/secrets.env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "${SCRIPT_NAME}: cannot locate lib/ directory" >&2
    exit 1
fi

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"

# === CLI ================================================================
ALL=false
DRY_RUN=false
NON_INTERACTIVE=false
TENANT_IDS=()

usage() {
    cat <<EOF
migrate-mongo-auth.sh — enable SCRAM auth on pre-migration tenants.

Usage:
  migrate-mongo-auth.sh <tenant_id> [<tenant_id>...] [options]
  migrate-mongo-auth.sh --all [options]

Options:
  --all                back up every tenant with status=active in the registry
  --non-interactive    skip the "proceed?" prompt (for scripting / cron)
  --dry-run            print what would happen; make no changes
  -h, --help

Per-tenant downtime (~30-60s each) while mongod bounces + bebop@ restarts.
Rolling: one at a time; --all runs sequentially, no fan-out.
EOF
}

while (( $# )); do
    case "$1" in
        --all)              ALL=true; shift ;;
        --non-interactive)  NON_INTERACTIVE=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        --) shift; break ;;
        -*) usage; die "unknown option: $1" ;;
        *)  TENANT_IDS+=("$1"); shift ;;
    esac
done

if [[ "$ALL" == "true" && ${#TENANT_IDS[@]} -gt 0 ]]; then
    die "--all is mutually exclusive with explicit tenant ids"
fi
if [[ "$ALL" != "true" && ${#TENANT_IDS[@]} -eq 0 ]]; then
    usage; die "specify at least one tenant_id, or --all"
fi

require_privileges

if [[ ! -f "$SECRETS_FILE" ]]; then
    die "secrets file not found: ${SECRETS_FILE}"
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

if [[ ! -f "/etc/be-BOP-mongodb/keyfile" ]]; then
    die "/etc/be-BOP-mongodb/keyfile missing — re-run host-bootstrap.sh first"
fi

registry_init

if [[ "$ALL" == "true" ]]; then
    mapfile -t TENANT_IDS < <(registry_list_by_status active)
fi

if (( ${#TENANT_IDS[@]} == 0 )); then
    log_info "no active tenants to migrate"
    exit 0
fi

log_info "candidates: ${#TENANT_IDS[@]} tenant(s): ${TENANT_IDS[*]}"
if [[ "$NON_INTERACTIVE" != "true" && "$DRY_RUN" != "true" ]]; then
    read -r -p "Proceed with rolling migration (~30-60s downtime per tenant) ? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) die "aborted by operator" ;;
    esac
fi

# === Per-tenant migration ===============================================
SUCCEEDED=()
SKIPPED=()
FAILED=()

migrate_one() {
    local tid="$1"
    BEBOP_TOOLING_TENANT_ID="$tid"
    export BEBOP_TOOLING_TENANT_ID

    local port_env="/etc/be-BOP-mongodb/${tid}/port.env"
    local cfg_env="/etc/be-BOP/${tid}/config.env"
    if [[ ! -f "$port_env" ]]; then
        die "port.env missing for '${tid}' (${port_env})"
    fi
    if [[ ! -f "$cfg_env" ]]; then
        die "config.env missing for '${tid}' (${cfg_env})"
    fi

    # Idempotence: a tenant is considered "already migrated" ONLY when BOTH
    # port.env has a QUOTED MONGO_AUTH_ARGS AND config.env's MONGODB_URL is
    # in the clean authed format (ending exactly at `&replicaSet=rs0`, no
    # trailing garbage). If either is off (partial migration crashed
    # between step 4 and step 6, OR the previous sed corruption produced
    # a concatenated line), we resume from step 2 — regress port.env to
    # unauth, reset password, rewrite everything cleanly.
    local port_env_has_auth=false url_has_creds=false
    grep -qE '^MONGO_AUTH_ARGS="' "$port_env" && port_env_has_auth=true
    if grep -qE '^MONGODB_URL=mongodb://[^@]+@[^?]+\?authSource=[^&]+&replicaSet=rs0$' "$cfg_env"; then
        url_has_creds=true
    fi
    if $port_env_has_auth && $url_has_creds; then
        # State on disk is clean. If bebop@<t> happens to be in a failed
        # state (e.g. crash-loop from a previous buggy preflight that got
        # patched since), reset-failed + restart to bring it back on the
        # fresh preflight code. No-op when it's already active.
        if run_privileged systemctl is-active --quiet "bebop@${tid}.service"; then
            log_info "already migrated + bebop@${tid} active — skip"
        else
            log_warn "already migrated but bebop@${tid} not active — resetting + restarting"
            run_privileged systemctl reset-failed "bebop@${tid}.service" 2>/dev/null || true
            if ! run_privileged systemctl restart "bebop@${tid}.service"; then
                log_error "bebop@${tid} failed to restart despite clean config"
                FAILED+=("$tid")
                return 1
            fi
        fi
        SKIPPED+=("$tid")
        return 0
    fi
    if $port_env_has_auth && ! $url_has_creds; then
        log_warn "partial migration detected (port.env authed, config.env not) — resuming from step 3"
    fi

    local mongo_port mongo_db
    mongo_port=$(registry_get_field "$tid" mongo_port)
    mongo_db=$(registry_get_field "$tid" mongodb_database)
    [[ -z "$mongo_port" || -z "$mongo_db" ]] \
        && die "registry missing mongo_port / mongodb_database for '${tid}'"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would: stop bebop@${tid} → create SCRAM user 'bebop_${tid//-/_}' on db '${mongo_db}' via localhost exception → rewrite port.env with MONGO_AUTH_ARGS → daemon-reload + restart mongod@${tid} → rewrite config.env MONGODB_URL → start bebop@${tid}"
        SUCCEEDED+=("$tid")
        return 0
    fi

    log_info "step 1/6: stopping bebop@${tid}.service..."
    run_privileged systemctl stop "bebop@${tid}.service" 2>/dev/null || true

    log_info "step 2/6: forcing mongod@${tid} into UNAUTH mode for user creation..."
    # Regress port.env to no-auth. No-op when it was already unauth.
    # Necessary on partial-migration resume: if port.env is currently
    # authed but config.env still lacks creds, a previous run crashed
    # between step 4 and step 6. The SCRAM user exists with a password
    # known only to that crashed run. With --auth off, mongo_create_user
    # (updateUser path) can reset the password without needing to
    # authenticate first. With --auth on, both localhost exception
    # (closes once a user exists) and unauth updates are impossible.
    local unauth_tmp
    unauth_tmp=$(mktemp)
    printf 'MONGO_PORT=%s\n' "$mongo_port" > "$unauth_tmp"
    run_privileged install -m 0640 "$unauth_tmp" "$port_env"
    rm -f "$unauth_tmp"
    run_privileged systemctl daemon-reload
    run_privileged systemctl restart "mongod@${tid}.service"
    mongo_wait_ready "$mongo_port" 60 1 \
        || die "mongod@${tid} did not become ready in unauth mode on port ${mongo_port}"

    log_info "step 3/6: creating SCRAM user via localhost exception..."
    local user="bebop_${tid//-/_}"
    local pwd
    pwd=$(mongo_generate_password)
    mongo_create_user "$mongo_port" "$mongo_db" "$user" "$pwd" \
        || die "SCRAM user creation failed for '${tid}'"

    log_info "step 4/6: enabling auth in port.env + daemon-reload + restart mongod@${tid}..."
    local tmp
    tmp=$(mktemp)
    # See add-tenant.sh:_write_mongo_port_env_with_auth for the quoting
    # rationale (systemd EnvironmentFile OK, bash `source` requires quotes).
    printf 'MONGO_PORT=%s\nMONGO_AUTH_ARGS="--auth --keyFile /run/credentials/mongod@%s.service/keyfile"\n' \
        "$mongo_port" "$tid" > "$tmp"
    run_privileged install -m 0640 "$tmp" "$port_env"
    rm -f "$tmp"
    run_privileged systemctl daemon-reload
    run_privileged systemctl restart "mongod@${tid}.service"

    log_info "step 5/6: verifying authenticated connection..."
    local uri
    uri=$(mongo_build_url_authed "$mongo_port" "$mongo_db" "$user" "$pwd")
    mongo_wait_ready "$uri" 60 1 \
        || die "mongod@${tid} did not answer authed ping after restart"

    log_info "step 6/6: rewriting MONGODB_URL in ${cfg_env}..."
    local cfg_tmp
    cfg_tmp=$(mktemp)
    # awk (not sed): sed's replacement string treats '&' as "the entire
    # match", corrupting our URI which contains '&' (authSource=X&replicaSet=Y).
    # awk's $0=STRING assignment is literal — no metacharacter interpretation.
    # Filter out ALL existing MONGODB_URL= lines (there may be several if
    # a prior corrupted run wrote them), then append exactly one clean line.
    run_privileged awk '!/^MONGODB_URL=/' "$cfg_env" > "$cfg_tmp"
    printf 'MONGODB_URL=%s\n' "$uri" >> "$cfg_tmp"
    run_privileged install -m 0640 "$cfg_tmp" "${cfg_env}.new"
    run_privileged mv -T "${cfg_env}.new" "$cfg_env"
    rm -f "$cfg_tmp"

    log_info "starting bebop@${tid}.service..."
    run_privileged systemctl start "bebop@${tid}.service" \
        || die "bebop@${tid} failed to start after migration"

    log_info "migrated OK (user='${user}', role=dbOwner on '${mongo_db}')"
    SUCCEEDED+=("$tid")
}

for t in "${TENANT_IDS[@]}"; do
    if ( migrate_one "$t" ); then
        :
    else
        FAILED+=("$t")
        log_error "migrate-mongo-auth: ${t} FAILED — continuing with next tenant"
    fi
    BEBOP_TOOLING_TENANT_ID=""
    export BEBOP_TOOLING_TENANT_ID
done

# === Summary ============================================================
cat <<EOF

==========================================================================
  migrate-mongo-auth summary
==========================================================================
  Selected:   ${#TENANT_IDS[@]}
  Migrated:   ${#SUCCEEDED[@]}  ${SUCCEEDED[*]:-}
  Skipped:    ${#SKIPPED[@]}    ${SKIPPED[*]:-}   (already had auth)
  Failed:     ${#FAILED[@]}     ${FAILED[*]:-}
==========================================================================
EOF

if (( ${#FAILED[@]} > 0 )); then
    notify_failure \
        "[be-BOP tooling] migrate-mongo-auth FAILED on $(hostname)" \
        "$(printf 'Failed tenants: %s\nSee: journalctl -t %s --since "1 hour ago"\n' \
            "${FAILED[*]}" "$BEBOP_TOOLING_SYSLOG_IDENT")" \
        || true
    exit 1
fi
exit 0

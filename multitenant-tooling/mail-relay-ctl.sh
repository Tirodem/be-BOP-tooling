#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# mail-relay-ctl.sh — operator CLI over the tooling MongoDB state.
#
# Talks to the dedicated mongod@tooling instance on 127.0.0.1:27100
# (database `bebop_tooling`) via mongosh. The relay reads the same
# collections on every SMTP connection, so any change is picked up on the
# next SMTP AUTH — no restart, no signal.
#
# Commands:
#   create <tenant_id>              generate a random password, insert the
#                                    tenant doc, print user + password to
#                                    stdout on ONE line (tab-separated) so
#                                    add-tenant.sh can capture it
#   delete <tenant_id>              remove the doc + all its send_log +
#                                    alert_state entries
#   list [--all]                    list active tenants (or all statuses)
#   show <tenant_id>                dump the tenant doc + recent counters
#                                    (10min / 24h / month) + last 10 sends
#   set-quota <tenant_id> <window>=<hard>[,<soft>]  [<window>=<hard>[,<soft>]]...
#                                    override quotas for one tenant; "-"
#                                    to reset to daemon defaults
#   set-status <tenant_id> <status>  active | disabled
#   set-upstream-id <tenant_id> <domain_id>|-
#                                    stamp (or clear with "-") the tenant's
#                                    upstream provider domain id. A NULL id
#                                    is the flag the retry-upstream sweep
#                                    looks for.
#   reset-tenant <tenant_id>        rotate password (rare — compromise
#                                    recovery); prints new password on stdout
#   prune-send-log [--older-than-days=90]
#                                    delete send_log rows past retention
#   retry-upstream <tenant_id>|--all  declare the tenant's sending domain
#                                    upstream (via lib/scaleway.sh's
#                                    adapter, which exposes a
#                                    provider-agnostic mail_upstream_* API).
#                                    Silent no-op if the operator hasn't
#                                    provided upstream credentials yet.

set -eEuo pipefail

readonly SCRIPT_NAME="mail-relay-ctl"

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
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# retry-upstream needs SCALEWAY_TEM_* and provider DNS creds from
# secrets.env. Without this source, mail_upstream_is_configured returns
# false silently (all env vars empty), retry-upstream no-ops, and the
# operator sees no output at all — worst possible UX. Other commands
# don't need secrets but sourcing is cheap and idempotent.
SECRETS_FILE="${SECRETS_FILE:-/etc/be-BOP-tooling/secrets.env}"
if [[ -r "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
fi

MONGO_PORT="${BEBOP_TOOLING_MONGO_PORT:-27100}"
MONGO_DB="${BEBOP_TOOLING_MONGO_DB:-bebop_tooling}"

# The tenant slug rules must match add-tenant.sh / test-tenant-api.py.
# Enforced here as a defence-in-depth: any tenant_id we let through to
# mongosh gets interpolated into a JS single-quoted string literal, so a
# stray apostrophe would be a real risk without this whitelist.
readonly TENANT_REGEX='^[a-z0-9][a-z0-9-]{0,31}$'

usage() {
    cat <<EOF
mail-relay-ctl.sh — manage the tooling MongoDB state used by the mail-relay.

Usage:
  mail-relay-ctl create <tenant_id>
  mail-relay-ctl delete <tenant_id>
  mail-relay-ctl list [--all]
  mail-relay-ctl show <tenant_id>
  mail-relay-ctl set-quota <tenant_id> <window>=<hard>[,<soft>] [<window>=<hard>[,<soft>]]...
      <window> ∈ { 10min, 24h, month }
      <hard>, <soft> integers; use "-" to reset to daemon defaults
  mail-relay-ctl set-status <tenant_id> {active|disabled}
  mail-relay-ctl set-upstream-id <tenant_id> <domain_id>|-
  mail-relay-ctl reset-tenant <tenant_id>
  mail-relay-ctl prune-send-log [--older-than-days=90]
  mail-relay-ctl retry-upstream <tenant_id>|--all
  mail-relay-ctl -h | --help
EOF
}

die() { printf '[%s] FATAL: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

# One point of truth for "does this tenant slug look sane?".
_check_tenant_id() {
    local id="$1"
    [[ -z "$id" ]] && die "tenant_id is required"
    [[ "$id" =~ $TENANT_REGEX ]] \
        || die "invalid tenant_id '${id}': must match ${TENANT_REGEX}"
}

# Run a mongosh JS snippet against the tooling database. All output goes to
# stdout; mongosh's status logs are silenced via --quiet.
_mongo() {
    local js="$1"
    run_privileged mongosh --quiet --port "$MONGO_PORT" \
        --eval "$js" "$MONGO_DB"
}

# Random password using /dev/urandom (base64-safe alphabet, 32 chars).
_gen_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
    printf '\n'
}

# bcrypt hashing runs in Python (aligned with the daemon's verifier). Cost
# 12 chosen to keep AUTH under ~200ms on modest hardware.
#
# The password is passed via env var — never argv (visible in `ps`), never
# stdin. `python3 - <<HEREDOC` uses stdin to receive the Python source
# itself, so any pipe attached upstream would be silently discarded and
# `sys.stdin.read()` would return '' — which used to hash the empty
# string for every tenant (see 2026-07 incident).
_bcrypt_hash() {
    local pw="$1"
    BEBOP_MAIL_RELAY_PW="$pw" python3 - <<'PYEOF'
import bcrypt, os, sys
pw = os.environ['BEBOP_MAIL_RELAY_PW'].encode('utf-8')
sys.stdout.write(bcrypt.hashpw(pw, bcrypt.gensalt(12)).decode('utf-8'))
PYEOF
}

cmd_create() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    local exists
    exists=$(_mongo "print(db.tenants.countDocuments({_id:'${tenant_id}'}));")
    [[ "$exists" != "0" ]] \
        && die "tenant '${tenant_id}' already exists — use reset-tenant to rotate its password"
    local password hash
    password=$(_gen_password)
    hash=$(_bcrypt_hash "$password")
    _mongo "db.tenants.insertOne({_id:'${tenant_id}', pass_hash:'${hash}', mail_status:'active', upstream_domain_id:null, created_at:new Date()});" >/dev/null
    printf '%s\t%s\n' "$tenant_id" "$password"
    log_info "created tenant '${tenant_id}' (password printed to stdout)"
}

cmd_delete() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    _mongo "
        db.alert_state.deleteMany({'_id.tenant':'${tenant_id}'});
        db.send_log.deleteMany({tenant_id:'${tenant_id}'});
        var r = db.tenants.deleteOne({_id:'${tenant_id}'});
        print(r.deletedCount);
    " >/dev/null
    log_info "deleted tenant '${tenant_id}'"
}

cmd_list() {
    local filter='{}'
    [[ "${1:-}" != "--all" ]] && filter="{mail_status:'active'}"
    _mongo "
        var docs = db.tenants.find(${filter}, {mail_status:1, upstream_domain_id:1, created_at:1}).sort({_id:1}).toArray();
        print('tenant_id                        mail_status  upstream  created_at');
        docs.forEach(function(d) {
            var up = d.upstream_domain_id ? 'yes' : 'no';
            var created = d.created_at ? d.created_at.toISOString() : '';
            print(d._id.padEnd(32) + ' ' + (d.mail_status || '').padEnd(11) + '  ' + up.padEnd(8) + '  ' + created);
        });
    "
}

cmd_show() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    _mongo "
        var t = db.tenants.findOne({_id:'${tenant_id}'});
        if (!t) { print('tenant \'${tenant_id}\' not found'); quit(1); }
        print('== Tenant doc ==');
        printjson(t);
        print('');
        print('== Send counters (accepted only) ==');
        var now = new Date();
        var windows = [
            {name:'10min', ms: 10*60*1000},
            {name:'24h',   ms: 24*60*60*1000},
            {name:'month', ms: 30*24*60*60*1000},
        ];
        windows.forEach(function(w) {
            var n = db.send_log.countDocuments({
                tenant_id:'${tenant_id}',
                status:{\$in:['sent-upstream','log-only']},
                sent_at:{\$gte: new Date(now.getTime() - w.ms)},
            });
            print(w.name + '\t' + n);
        });
        print('');
        print('== Last 10 sends ==');
        db.send_log.find({tenant_id:'${tenant_id}'}).sort({sent_at:-1}).limit(10).forEach(function(d) {
            print(d.sent_at.toISOString() + '  ' + d.status + '  ' + d.size_bytes + '  ' + d.recipient);
        });
    "
}

# Compose the $set portion of the update from window=hard[,soft] args.
# Emits JS object fragments that get spliced into the mongosh command.
_quota_sets_js() {
    local -a sets=()
    local arg window rest hard soft field_hard field_soft
    for arg in "$@"; do
        [[ "$arg" =~ ^([A-Za-z0-9]+)=(.*)$ ]] || die "malformed quota arg '${arg}'"
        window="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        hard="${rest%%,*}"
        soft=""
        [[ "$rest" == *","* ]] && soft="${rest#*,}"
        case "$window" in
            10min) field_hard=hard_cap_10min; field_soft=soft_alert_10min ;;
            24h)   field_hard=hard_cap_24h;   field_soft=soft_alert_24h ;;
            month) field_hard=hard_cap_month; field_soft=soft_alert_month ;;
            *) die "unknown window '${window}' (want 10min|24h|month)" ;;
        esac
        if [[ -z "$hard" ]]; then
            :
        elif [[ "$hard" == "-" ]]; then
            sets+=("'${field_hard}':null")
        elif [[ "$hard" =~ ^[0-9]+$ ]]; then
            sets+=("'${field_hard}':${hard}")
        else
            die "hard cap for '${window}' must be an integer or '-' (got '${hard}')"
        fi
        if [[ -n "$soft" ]]; then
            if [[ "$soft" == "-" ]]; then
                sets+=("'${field_soft}':null")
            elif [[ "$soft" =~ ^[0-9]+$ ]]; then
                sets+=("'${field_soft}':${soft}")
            else
                die "soft alert for '${window}' must be an integer or '-' (got '${soft}')"
            fi
        fi
    done
    local IFS=,
    echo "${sets[*]}"
}

cmd_set_quota() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    shift
    (( $# > 0 )) || die "at least one <window>=<hard>[,<soft>] required"
    local sets_js
    sets_js=$(_quota_sets_js "$@")
    [[ -z "$sets_js" ]] && die "no quota fields to update"
    _mongo "db.tenants.updateOne({_id:'${tenant_id}'}, {\$set:{${sets_js}}});" >/dev/null
    log_info "quotas updated for '${tenant_id}': {${sets_js}}"
}

cmd_set_status() {
    local tenant_id="${1:-}"
    local status="${2:-}"
    _check_tenant_id "$tenant_id"
    case "$status" in
        active|disabled) ;;
        *) die "status must be one of: active | disabled" ;;
    esac
    _mongo "db.tenants.updateOne({_id:'${tenant_id}'}, {\$set:{mail_status:'${status}'}});" >/dev/null
    log_info "tenant '${tenant_id}' status → ${status}"
}

cmd_set_upstream_id() {
    local tenant_id="${1:-}"
    local domain_id="${2:-}"
    _check_tenant_id "$tenant_id"
    [[ -z "$domain_id" ]] && die "set-upstream-id needs a domain id (or '-' to clear)"
    if [[ "$domain_id" == "-" ]]; then
        _mongo "db.tenants.updateOne({_id:'${tenant_id}'}, {\$set:{upstream_domain_id:null}});" >/dev/null
        log_info "tenant '${tenant_id}' upstream_domain_id → null"
    else
        # The domain id comes from the provider adapter; validate it's
        # printable ASCII to keep JS-string interpolation safe.
        [[ "$domain_id" =~ ^[A-Za-z0-9._-]+$ ]] \
            || die "upstream_domain_id contains unexpected characters: '${domain_id}'"
        _mongo "db.tenants.updateOne({_id:'${tenant_id}'}, {\$set:{upstream_domain_id:'${domain_id}'}});" >/dev/null
        log_info "tenant '${tenant_id}' upstream_domain_id → ${domain_id}"
    fi
}

cmd_reset_tenant() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    local exists
    exists=$(_mongo "print(db.tenants.countDocuments({_id:'${tenant_id}'}));")
    [[ "$exists" == "0" ]] && die "tenant '${tenant_id}' does not exist"
    local password hash
    password=$(_gen_password)
    hash=$(_bcrypt_hash "$password")
    _mongo "db.tenants.updateOne({_id:'${tenant_id}'}, {\$set:{pass_hash:'${hash}'}});" >/dev/null
    printf '%s\t%s\n' "$tenant_id" "$password"
    log_warn "password rotated for '${tenant_id}' — reseed runtimeConfig.smtp on the tenant side"
}

cmd_prune_send_log() {
    local days=90
    for arg in "$@"; do
        case "$arg" in
            --older-than-days=*) days="${arg#*=}" ;;
            *) die "unknown arg: $arg" ;;
        esac
    done
    [[ "$days" =~ ^[0-9]+$ ]] || die "--older-than-days must be an integer"
    local out
    out=$(_mongo "
        var cutoff = new Date(Date.now() - ${days}*24*60*60*1000);
        var r = db.send_log.deleteMany({sent_at:{\$lt: cutoff}});
        print(r.deletedCount);
    ")
    log_info "prune-send-log: deleted ${out} row(s) older than ${days} days"
}

cmd_retry_upstream() {
    # Declares each pending tenant's sending domain against the upstream
    # provider (Scaleway TEM in V1, whatever else later). The provider
    # specifics live inside lib/scaleway.sh — the adapter exposes a
    # provider-agnostic mail_upstream_* surface (is_configured,
    # setup_domain, teardown_domain). This function only knows that surface.
    #
    # No-op if the operator hasn't set up an upstream yet — the fake SMTP
    # works standalone. The timer (bebop-mail-relay-retry.timer) invokes
    # this every 15 min so provisioned tenants get their upstream declared
    # as soon as credentials appear in secrets.env. When invoked manually
    # by an operator (from CLI, single tenant), we surface the no-op as
    # log_warn so silence-with-no-output doesn't leave the operator
    # wondering whether it worked. The timer path stays quiet via
    # log_debug — no need to spam the journal at every tick.
    local target="${1:-}"
    [[ -z "$target" ]] && { usage; die "retry-upstream needs a tenant_id or --all"; }

    # shellcheck source=lib/scaleway.sh
    source "${BEBOP_TOOLING_LIB_DIR}/scaleway.sh"
    # shellcheck source=lib/dns_provider.sh
    source "${BEBOP_TOOLING_LIB_DIR}/dns_provider.sh"

    if ! mail_upstream_is_configured; then
        if [[ "$target" == "--all" ]]; then
            log_debug "retry-upstream --all: no upstream provider configured — noop"
        else
            log_warn "retry-upstream: no upstream provider configured — set SCALEWAY_TEM_API_KEY + SCALEWAY_TEM_PROJECT_ID in ${SECRETS_FILE} and retry"
        fi
        return 0
    fi
    [[ -z "${BEBOP_DNS_ZONE:-}" ]] && die "retry-upstream: BEBOP_DNS_ZONE unset — cannot compose sending domains"

    if [[ "$target" == "--all" ]]; then
        local ids
        ids=$(_mongo "
            db.tenants.find(
                {upstream_domain_id:null, mail_status:'active'},
                {_id:1}
            ).sort({_id:1}).forEach(function(d) { print(d._id); });
        ")
        if [[ -z "$ids" ]]; then
            log_debug "retry-upstream --all: no tenants pending upstream declaration"
            return 0
        fi
        local id
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            _do_upstream_setup "$id"
        done <<< "$ids"
        return 0
    fi
    _check_tenant_id "$target"
    _do_upstream_setup "$target"
}

# Runs one tenant through the upstream setup. Non-fatal on failure — the
# timer will retry next tick. Returns 0 on success, non-zero otherwise.
_do_upstream_setup() {
    local tid="$1"
    local full_domain="${tid}.${BEBOP_DNS_ZONE}"
    log_info "retry-upstream: declaring '${full_domain}' upstream..."
    local domain_id
    if ! domain_id=$(mail_upstream_setup_domain "$tid" "$full_domain"); then
        log_warn "retry-upstream: setup failed for '${tid}' — will retry"
        return 1
    fi
    cmd_set_upstream_id "$tid" "$domain_id"
    log_info "retry-upstream: '${tid}' declared (id=${domain_id})"
}

main() {
    (( $# == 0 )) && { usage; exit 1; }
    require_privileges
    # Verify bebop-tooling-mongodb is reachable AND its replica set is
    # in a state we can write against. A raw ping succeeds even when the
    # node is SECONDARY without a primary elected (or in STARTUP), so the
    # ping alone would let us continue to the actual command and hit the
    # infamous "node is not in primary or recovering state" error inside
    # cmd_create/cmd_delete/etc. mongo_init_rs is idempotent (skips if
    # rs.status().ok already), so calling it here on every invocation
    # both self-heals a fresh mongod (never started as part of a
    # bebop-mail-relay boot cycle) and validates the RS state before any
    # write. Costs one mongosh ping on a healthy tenant.
    if ! run_privileged mongosh --quiet --port "$MONGO_PORT" \
            --eval 'db.runCommand({ping:1}).ok' "$MONGO_DB" >/dev/null 2>&1; then
        die "cannot reach bebop-tooling-mongodb on 127.0.0.1:${MONGO_PORT} — is it running?"
    fi
    if ! mongo_init_rs "$MONGO_PORT" >/dev/null 2>&1; then
        die "bebop-tooling-mongodb: replica set not initialised on 127.0.0.1:${MONGO_PORT} and mongo_init_rs failed"
    fi
    local cmd="$1"; shift
    case "$cmd" in
        create)          cmd_create "$@" ;;
        delete)          cmd_delete "$@" ;;
        list)            cmd_list "$@" ;;
        show)            cmd_show "$@" ;;
        set-quota)       cmd_set_quota "$@" ;;
        set-status)      cmd_set_status "$@" ;;
        set-upstream-id) cmd_set_upstream_id "$@" ;;
        reset-tenant)    cmd_reset_tenant "$@" ;;
        prune-send-log)  cmd_prune_send_log "$@" ;;
        retry-upstream)  cmd_retry_upstream "$@" ;;
        -h|--help|help)  usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"

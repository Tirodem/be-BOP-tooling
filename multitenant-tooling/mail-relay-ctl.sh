#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# mail-relay-ctl.sh — operator CLI over the local mail-relay SQLite state.
#
# Talks to /var/lib/be-BOP/mail-relay/state.db directly via sqlite3. The
# relay reads the same table on every connection (short-lived conns), so
# any change is picked up on the next SMTP AUTH — no restart, no signal.
#
# Commands:
#   create <tenant_id>              generate a random password, upsert the
#                                    tenant row, print user + password to
#                                    stdout on ONE line (tab-separated) so
#                                    add-tenant.sh can capture it
#   delete <tenant_id>              remove the row + all its send_log +
#                                    alert_state entries
#   list [--all]                    list active tenants (or all statuses)
#   show <tenant_id>                dump the tenant row + recent counters
#                                    (10min / 24h / month)
#   set-quota <tenant_id> <window>=<hard>[,<soft>]  [<window>=<hard>[,<soft>]]...
#                                    override quotas for one tenant; NULL
#                                    to reset to daemon defaults
#   set-status <tenant_id> <status>  active | pending | failed | disabled
#   reset-tenant <tenant_id>        rotate password (rare — compromise
#                                    recovery); prints new password on stdout
#   prune-send-log [--older-than-days=90]
#                                    delete send_log rows past retention
#   retry-scaleway <tenant_id|--all>  hook for the milestone-6 retry loop.
#                                    In this milestone: log-only stub.

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

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

DB_PATH="${BEBOP_MAIL_RELAY_DB:-/var/lib/be-BOP/mail-relay/state.db}"

# The tenant slug rules must match add-tenant.sh / test-tenant-api.py.
# Enforced here as a defence-in-depth against `mail-relay-ctl create '; DROP …'`.
readonly TENANT_REGEX='^[a-z0-9][a-z0-9-]{0,31}$'

usage() {
    cat <<EOF
mail-relay-ctl.sh — manage the local be-BOP mail-relay SQLite state.

Usage:
  mail-relay-ctl create <tenant_id>
  mail-relay-ctl delete <tenant_id>
  mail-relay-ctl list [--all]
  mail-relay-ctl show <tenant_id>
  mail-relay-ctl set-quota <tenant_id> <window>=<hard>[,<soft>] [<window>=<hard>[,<soft>]]...
      <window> ∈ { 10min, 24h, month }
      <hard>, <soft> integers; use "-" to reset to daemon defaults
  mail-relay-ctl set-status <tenant_id> {active|pending|failed|disabled}
  mail-relay-ctl reset-tenant <tenant_id>
  mail-relay-ctl prune-send-log [--older-than-days=90]
  mail-relay-ctl retry-scaleway <tenant_id>|--all
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

# sqlite3 wrapper: forces sudo when needed, always in autocommit mode. We
# route via -cmd '.timeout 10000' so a long-lived relai lock doesn't wedge
# the CLI (WAL mode reads should not block writes here, but belt+suspenders).
_sq() {
    run_privileged sqlite3 -bail -cmd '.timeout 10000' "$DB_PATH" "$@"
}

# All string values are single-quote-escaped before being passed into
# sqlite3 statements; the DB path itself is trusted (root-owned).
_sqlq() { printf "%s" "$1" | sed "s/'/''/g"; }

# Random password using /dev/urandom (base64, 32 chars). Aligned with the
# strength of the tenant-side runtimeConfig persistence — a compromise on
# either side would be catastrophic regardless of relay password entropy.
_gen_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
    printf '\n'
}

# bcrypt hashing runs in Python (aligned with the daemon's verifier). Cost
# 12 chosen to keep AUTH under ~200ms on modest hardware; adjust if you
# hit issues with high login rates.
_bcrypt_hash() {
    local pw="$1"
    python3 - <<PYEOF
import bcrypt, sys
pw = sys.stdin.read().rstrip('\n').encode('utf-8')
sys.stdout.write(bcrypt.hashpw(pw, bcrypt.gensalt(12)).decode('utf-8'))
PYEOF
}

cmd_create() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    local existing
    existing=$(_sq "SELECT tenant_id FROM tenants WHERE tenant_id='$(_sqlq "$tenant_id")';" 2>/dev/null || true)
    [[ -n "$existing" ]] && die "tenant '${tenant_id}' already exists — use reset-tenant to rotate its password"
    local password
    password=$(_gen_password)
    local hash
    hash=$(printf '%s' "$password" | _bcrypt_hash "$password")
    _sq "INSERT INTO tenants (tenant_id, pass_hash) VALUES ('$(_sqlq "$tenant_id")', '$(_sqlq "$hash")');"
    # Tab-separated so add-tenant.sh can parse with `cut -f1,2`.
    printf '%s\t%s\n' "$tenant_id" "$password"
    log_info "created tenant '${tenant_id}' (password printed to stdout)"
}

cmd_delete() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    local rc
    rc=$(_sq "SELECT changes() FROM (SELECT 1 FROM tenants WHERE tenant_id='$(_sqlq "$tenant_id")');" 2>/dev/null || echo 0)
    _sq \
        "DELETE FROM alert_state WHERE tenant_id='$(_sqlq "$tenant_id")';" \
        "DELETE FROM send_log WHERE tenant_id='$(_sqlq "$tenant_id")';" \
        "DELETE FROM tenants WHERE tenant_id='$(_sqlq "$tenant_id")';"
    log_info "deleted tenant '${tenant_id}' (was ${rc:+present})"
}

cmd_list() {
    local status_filter=""
    [[ "${1:-}" != "--all" ]] && status_filter="WHERE mail_status='active'"
    _sq -header -column \
        "SELECT tenant_id, mail_status, created_at FROM tenants ${status_filter} ORDER BY tenant_id;"
}

cmd_show() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    local q="$(_sqlq "$tenant_id")"
    echo "== Tenant row =="
    _sq -header -column \
        "SELECT tenant_id, mail_status, hard_cap_10min, hard_cap_24h, hard_cap_month, soft_alert_10min, soft_alert_24h, soft_alert_month, created_at FROM tenants WHERE tenant_id='${q}';"
    echo
    echo "== Send counters (accepted only) =="
    _sq -header -column "
        SELECT '10min' AS window, COUNT(*) AS accepted FROM send_log
            WHERE tenant_id='${q}' AND status='accepted'
              AND sent_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes')
        UNION ALL
        SELECT '24h', COUNT(*) FROM send_log
            WHERE tenant_id='${q}' AND status='accepted'
              AND sent_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 day')
        UNION ALL
        SELECT 'month', COUNT(*) FROM send_log
            WHERE tenant_id='${q}' AND status='accepted'
              AND sent_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-30 days');
    "
    echo
    echo "== Last 10 sends =="
    _sq -header -column \
        "SELECT sent_at, recipient, size_bytes, status FROM send_log WHERE tenant_id='${q}' ORDER BY id DESC LIMIT 10;"
}

cmd_set_quota() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    shift
    (( $# > 0 )) || die "at least one <window>=<hard>[,<soft>] required"
    local q="$(_sqlq "$tenant_id")"
    local sets=()
    local arg window rest hard soft col_hard col_soft
    for arg in "$@"; do
        [[ "$arg" =~ ^([A-Za-z0-9]+)=(.*)$ ]] || die "malformed quota arg '${arg}'"
        window="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        hard="${rest%%,*}"
        soft=""
        [[ "$rest" == *","* ]] && soft="${rest#*,}"
        case "$window" in
            10min) col_hard=hard_cap_10min; col_soft=soft_alert_10min ;;
            24h)   col_hard=hard_cap_24h;   col_soft=soft_alert_24h ;;
            month) col_hard=hard_cap_month; col_soft=soft_alert_month ;;
            *) die "unknown window '${window}' (want 10min|24h|month)" ;;
        esac
        if [[ "$hard" == "-" ]]; then
            sets+=("${col_hard}=NULL")
        elif [[ "$hard" =~ ^[0-9]+$ ]]; then
            sets+=("${col_hard}=${hard}")
        elif [[ -n "$hard" ]]; then
            die "hard cap for '${window}' must be an integer or '-' (got '${hard}')"
        fi
        if [[ -n "$soft" ]]; then
            if [[ "$soft" == "-" ]]; then
                sets+=("${col_soft}=NULL")
            elif [[ "$soft" =~ ^[0-9]+$ ]]; then
                sets+=("${col_soft}=${soft}")
            else
                die "soft alert for '${window}' must be an integer or '-' (got '${soft}')"
            fi
        fi
    done
    local joined
    joined=$(IFS=,; echo "${sets[*]}")
    _sq "UPDATE tenants SET ${joined} WHERE tenant_id='${q}';"
    log_info "quotas updated for '${tenant_id}': ${joined}"
}

cmd_set_status() {
    local tenant_id="${1:-}"
    local status="${2:-}"
    _check_tenant_id "$tenant_id"
    case "$status" in
        active|pending|failed|disabled) ;;
        *) die "status must be one of: active | pending | failed | disabled" ;;
    esac
    _sq "UPDATE tenants SET mail_status='$(_sqlq "$status")' WHERE tenant_id='$(_sqlq "$tenant_id")';"
    log_info "tenant '${tenant_id}' status → ${status}"
}

cmd_reset_tenant() {
    local tenant_id="${1:-}"
    _check_tenant_id "$tenant_id"
    local existing
    existing=$(_sq "SELECT tenant_id FROM tenants WHERE tenant_id='$(_sqlq "$tenant_id")';" 2>/dev/null || true)
    [[ -z "$existing" ]] && die "tenant '${tenant_id}' does not exist"
    local password
    password=$(_gen_password)
    local hash
    hash=$(printf '%s' "$password" | _bcrypt_hash "$password")
    _sq "UPDATE tenants SET pass_hash='$(_sqlq "$hash")' WHERE tenant_id='$(_sqlq "$tenant_id")';"
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
    local deleted
    deleted=$(_sq "DELETE FROM send_log WHERE sent_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-${days} days'); SELECT changes();")
    log_info "prune-send-log: deleted ${deleted} row(s) older than ${days} days"
}

cmd_retry_scaleway() {
    # Delegates the actual reprovisioning work to add-tenant.sh in reapply
    # mode. Reasons:
    #   - phase_mail_relay is state-aware (detects pending / failed rows and
    #     rotates the password + retries Scaleway), so the reapply is a
    #     natural retry.
    #   - Idempotent: any tenant already in mail_status=active is a fast
    #     no-op via the "already active — skipping" branch.
    #   - Restarts bebop@<tenant> at the end so a freshly seeded
    #     runtimeConfig.smtp is picked up immediately.
    local target="${1:-}"
    [[ -z "$target" ]] && { usage; die "retry-scaleway needs a tenant_id or --all"; }
    if [[ "$target" == "--all" ]]; then
        local ids
        ids=$(_sq "SELECT tenant_id FROM tenants WHERE mail_status IN ('pending', 'failed') ORDER BY tenant_id;")
        if [[ -z "$ids" ]]; then
            log_info "retry-scaleway --all: no tenants in pending/failed state"
            return 0
        fi
        local id
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            log_info "retry-scaleway: dispatching add-tenant.sh for '${id}'"
            if command -v add-tenant.sh >/dev/null 2>&1; then
                add-tenant.sh "$id" --non-interactive \
                    || log_warn "retry-scaleway: add-tenant.sh '${id}' exited non-zero"
            else
                log_warn "retry-scaleway: add-tenant.sh not on PATH — cannot retry '${id}'"
            fi
        done <<< "$ids"
        return 0
    fi
    _check_tenant_id "$target"
    log_info "retry-scaleway: dispatching add-tenant.sh for '${target}'"
    if ! command -v add-tenant.sh >/dev/null 2>&1; then
        die "retry-scaleway: add-tenant.sh not on PATH"
    fi
    add-tenant.sh "$target" --non-interactive
}

main() {
    (( $# == 0 )) && { usage; exit 1; }
    require_privileges
    [[ -f "$DB_PATH" ]] || die "relay DB not found at ${DB_PATH} — is bebop-mail-relay running?"
    local cmd="$1"; shift
    case "$cmd" in
        create)          cmd_create "$@" ;;
        delete)          cmd_delete "$@" ;;
        list)            cmd_list "$@" ;;
        show)            cmd_show "$@" ;;
        set-quota)       cmd_set_quota "$@" ;;
        set-status)      cmd_set_status "$@" ;;
        reset-tenant)    cmd_reset_tenant "$@" ;;
        prune-send-log)  cmd_prune_send_log "$@" ;;
        retry-scaleway)  cmd_retry_scaleway "$@" ;;
        -h|--help|help)  usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# freeze-tenant.sh — manage the frozen-tenants list.
#
# A frozen tenant is SKIPPED by upgrade-all.sh (manual --all run + nightly
# timer). Manual single-tenant upgrades (upgrade-tenant.sh <id>) ignore
# the freeze list on purpose — explicit target = explicit intent.
#
# Storage: $FREEZE_LIST_PATH (default /var/lib/be-BOP/frozen-tenants.txt),
# one tenant_id per line, # comments and blank lines ignored.

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="freeze-tenant"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "freeze-tenant: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/freeze.sh
source "$BEBOP_TOOLING_LIB_DIR/freeze.sh"

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
RUN_NON_INTERACTIVE=false

# === EXIT trap ==========================================================
# Armed AFTER CLI parsing (so usage/help paths don't notify). Happy paths
# in each mutation case set NOTIFIED=true after notify_success.
NOTIFIED=false
on_script_exit() {
    local rc=$?
    if [[ "$NOTIFIED" != "true" ]] && (( rc != 0 )); then
        NOTIFIED=true
        local body
        body=$(printf 'Subcommand: %s\nPositional args: %s\nExit code: %d\n\nSee journalctl -t %s --since "1 hour ago" for the full log.\n' \
            "${CMD:-(unset)}" "${POSITIONALS[*]:-(none)}" "$rc" \
            "${BEBOP_TOOLING_SYSLOG_IDENT}")
        notify_failure \
            "[be-BOP tooling] freeze-tenant ${CMD:-(unset)} FAILED" \
            "$body" || true
    fi
}

usage() {
    cat <<EOF
freeze-tenant.sh — manage the upgrade-all freeze list.

Usage:
  freeze-tenant.sh add <id> [<id>...]      add tenant(s) to the freeze list
  freeze-tenant.sh remove <id> [<id>...]   remove tenant(s) from the freeze list
  freeze-tenant.sh list                    print the frozen tenants
  freeze-tenant.sh clean                   wipe the freeze list (confirmation prompt)
  freeze-tenant.sh -h | --help

Options:
  --non-interactive    skip the confirmation prompt for "clean"

A frozen tenant is skipped by upgrade-all.sh (manual + nightly timer).
Single-tenant upgrades via upgrade-tenant.sh <id> IGNORE the freeze list.

Storage: $(freeze_list_path)
EOF
}

# Parse --non-interactive anywhere in args; collect positionals.
POSITIONALS=()
for a in "$@"; do
    case "$a" in
        --non-interactive) RUN_NON_INTERACTIVE=true ;;
        -h|--help) usage; exit 0 ;;
        *) POSITIONALS+=("$a") ;;
    esac
done
set -- "${POSITIONALS[@]+"${POSITIONALS[@]}"}"

(( $# == 0 )) && { usage; die "missing subcommand"; }

CMD="$1"; shift

# Most subcommands need privileges to write the list file under /var/lib/be-BOP.
case "$CMD" in
    list) ;;  # read-only
    *)    require_privileges ;;
esac

# Load Zulip/SMTP credentials so notify_* helpers can dispatch. Missing
# secrets.env is non-fatal — notify.sh helpers log_warn + skip on their
# own when ZULIP_* / SMTP_* are unset.
if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
else
    log_warn "secrets file not found: ${SECRETS_FILE} — Zulip/SMTP alerts disabled"
fi

# Arm the failure-notification trap NOW: from this point on, any non-zero
# exit (die, set -e, etc.) triggers a notify_failure unless a success path
# has already set NOTIFIED=true.
trap 'on_script_exit' EXIT

registry_init

ensure_list_file() {
    if ! run_privileged test -e "$FREEZE_LIST_PATH"; then
        run_privileged install -d -m 0755 "$(dirname "$FREEZE_LIST_PATH")"
        run_privileged install -m 0644 /dev/null "$FREEZE_LIST_PATH"
    fi
}

# Read current list (deduplicated, sorted) into stdout.
_current_list() { freeze_list_frozen; }

# Write a deduplicated sorted list, atomic via temp file + mv.
_write_list() {
    local tmp
    tmp=$(mktemp)
    # Preserve leading comments if any exist in the current file (file header).
    if run_privileged test -r "$FREEZE_LIST_PATH"; then
        run_privileged sed -n '/^[[:space:]]*#/p; /^[^#]/q' "$FREEZE_LIST_PATH" > "$tmp" || true
    fi
    # If no header, drop a stock one (first write).
    if [[ ! -s "$tmp" ]]; then
        cat > "$tmp" <<'EOF'
# be-BOP frozen-tenants list — managed by freeze-tenant.sh.
# Each non-comment line is a tenant_id that upgrade-all.sh will SKIP.
# Single-tenant upgrade-tenant.sh runs ignore this file.
EOF
    fi
    # Append the sorted unique ids.
    cat >> "$tmp"
    run_privileged install -m 0644 "$tmp" "$FREEZE_LIST_PATH"
    rm -f "$tmp"
}

case "$CMD" in

    add)
        (( $# > 0 )) || die "add: at least one tenant_id required"
        # Validate every id exists in the registry BEFORE writing — abort on
        # any typo to keep the operation atomic (no partial writes).
        local_unknown=()
        for t in "$@"; do
            s=$(registry_get_status "$t")
            [[ "$s" == "absent" ]] && local_unknown+=("$t")
        done
        if (( ${#local_unknown[@]} > 0 )); then
            die "add: unknown tenant(s) in registry: ${local_unknown[*]}"
        fi
        ensure_list_file
        # Union(current, new) → write.
        {
            _current_list
            printf '%s\n' "$@"
        } | sort -u | _write_list
        log_info "freeze: added: $*"
        frozen_now=$(_current_list)
        frozen_count=$(printf '%s\n' "$frozen_now" | grep -c . || true)
        notify_success \
            "[be-BOP tooling] freeze: added $* (${frozen_count} frozen)" \
            "Added: $*
Frozen tenants now:
${frozen_now}

upgrade-all.sh will SKIP these (manual + nightly timer).
Single-tenant upgrade-tenant.sh <id> still works."
        NOTIFIED=true
        ;;

    remove)
        (( $# > 0 )) || die "remove: at least one tenant_id required"
        ensure_list_file
        # current MINUS args → write (no validation needed; missing ids are no-op).
        local_to_keep=$(comm -23 \
            <(_current_list) \
            <(printf '%s\n' "$@" | sort -u))
        printf '%s\n' "$local_to_keep" | sed '/^$/d' | _write_list
        log_info "freeze: removed (no-op if not present): $*"
        frozen_now=$(_current_list)
        frozen_count=$(printf '%s\n' "$frozen_now" | grep -c . || true)
        notify_success \
            "[be-BOP tooling] freeze: removed $* (${frozen_count} frozen)" \
            "Removed (no-op if absent): $*
Frozen tenants now:
${frozen_now:-(none — list is empty)}"
        NOTIFIED=true
        ;;

    list)
        if ! freeze_list_frozen | grep -q .; then
            log_info "freeze list is empty ($(freeze_list_path))"
        else
            freeze_list_frozen
        fi
        ;;

    clean)
        wiped_count=$(_current_list | grep -c . || true)
        if [[ "$RUN_NON_INTERACTIVE" != "true" ]]; then
            echo "About to wipe ${wiped_count} frozen tenant(s) from $(freeze_list_path)."
            read -r -p "Continue ? [y/N] " ans
            case "$ans" in
                y|Y|yes|YES) ;;
                *) die "aborted by operator" ;;
            esac
        fi
        ensure_list_file
        : | _write_list
        log_info "freeze list cleaned"
        notify_success \
            "[be-BOP tooling] freeze list cleaned (${wiped_count} tenant(s) wiped)" \
            "All previously frozen tenants are now eligible for upgrade-all
again (manual + nightly timer)."
        NOTIFIED=true
        ;;

    *)
        usage; die "unknown subcommand: $CMD"
        ;;
esac

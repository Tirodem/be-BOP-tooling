#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# find-orphans.sh — detect and clean tenant artefacts that exist on the host
# but no longer have a matching row in /var/lib/be-BOP/tenants.tsv.
#
# An "orphan" is any tenant id that has at least one of the following
# artefacts on the host but is absent from every row of the registry:
#   - systemd unit enabled:  bebop@<id>.service, phoenixd@<id>.service,
#                            mongod@<id>.service
#   - config dir:            /etc/be-BOP/<id>/
#   - data dir:              /var/lib/be-BOP/<id>/
#   - mongo data dir:        /var/lib/be-BOP-mongodb/<id>/
#   - nginx vhost:           /etc/nginx/sites-available/bebop-<id>.conf
#   - LE cert(s):            /etc/letsencrypt/live/bebop-<id>/
#                            /etc/letsencrypt/live/bebop-<id>-s3/
#
# Orphans occur when a previous run of add-tenant.sh was killed after the
# systemd/nginx phases but before registry_add(), or when a registry row is
# edited/removed by hand without running remove-tenant.sh. Their most
# damaging effect is port collision: registry_allocate_port() scans only
# the registry, so an orphan's port can be handed out to a new tenant that
# will then fail with EADDRINUSE.
#
# Modes:
#   (default, --report)
#       List every orphan and the artefacts detected. Read-only.
#   --purge <id>
#       Remove all on-host artefacts of one orphan. Refuses if <id> is a
#       registered tenant. Prompts unless --yes or --non-interactive.
#   --purge-all
#       Same as --purge but iterates over every orphan detected.
#
# What this script does NOT touch:
#   - DNS records         (would need DNS provider creds; risky)
#   - Garage buckets/keys (may still hold customer data; use remove-tenant)
#   - Uptime Kuma monitor (no way to match by id)
#
# Options:
#   --yes                skip the interactive confirmation for purge modes
#   --non-interactive    prompts are treated as refusal
#   --dry-run            print actions without executing
#   --verbose
#   -h, --help

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="find-orphans"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "find-orphans: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

MODE="report"
TARGET_ID=""
ASSUME_YES=false
RUN_NON_INTERACTIVE=false
DRY_RUN=false
VERBOSE=false
export RUN_NON_INTERACTIVE VERBOSE DRY_RUN

usage() {
    cat <<EOF
find-orphans.sh — detect and clean tenant artefacts absent from the registry.

Usage:
  find-orphans.sh                         # report (default)
  find-orphans.sh --report                # report
  find-orphans.sh --purge <tenant_id>     # purge one orphan
  find-orphans.sh --purge-all             # purge every orphan detected

Options:
  --yes                skip confirmation prompts in purge modes
  --non-interactive    treat missing confirmation as refusal
  --dry-run            print actions without executing
  --verbose
  -h, --help

Safety:
  - purge modes refuse any id present in /var/lib/be-BOP/tenants.tsv
  - DNS records, Garage buckets, Kuma monitors are NEVER touched
EOF
}

while (( $# )); do
    case "$1" in
        --report)          MODE=report; shift ;;
        --purge)
            MODE=purge
            [[ -z "${2:-}" || "${2:0:2}" == "--" ]] \
                && die "--purge requires a tenant_id"
            TARGET_ID="$2"; shift 2 ;;
        --purge-all)       MODE=purge-all; shift ;;
        --yes)             ASSUME_YES=true; shift ;;
        --non-interactive) RUN_NON_INTERACTIVE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --verbose)         VERBOSE=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)  die "unexpected positional argument: $1 (try --help)" ;;
    esac
done

# === ID discovery =======================================================
#
# Each discovery function prints one id per line on stdout. We union the
# results and then filter out ids that appear in the registry.

# systemd: template-instance units that are *enabled*. An enable creates a
# symlink under a .wants/ directory of some target — we enumerate those.
# Ignoring list-units --all deliberately: it surfaces residual/failed
# instances long after their disk artefacts are gone, producing a lot of
# false positives with no actionable content.
discover_systemd_ids() {
    local template
    for template in bebop phoenixd mongod; do
        run_privileged find /etc/systemd/system -maxdepth 3 \
            -name "${template}@*.service" -type l \
            -printf '%f\n' 2>/dev/null \
            | sed -nE "s/^${template}@(.+)\\.service$/\\1/p" \
            | grep -v '^$' || true
    done
}

# On-disk directories under /etc and /var/lib. We scan BOTH the public
# StateDirectory symlink location (/var/lib/be-BOP-mongodb/…) AND the
# actual private target (/var/lib/private/be-BOP-mongodb/…) — the second
# path is where the data really lives when DynamicUser=yes is set on the
# service, and a purge that only checks the public path can miss data
# that survived a rm -rf on the symlink.
discover_dir_ids() {
    local base
    for base in /etc/be-BOP /etc/be-BOP-mongodb /etc/phoenixd \
                /var/lib/be-BOP /var/lib/be-BOP-mongodb /var/lib/phoenixd \
                /var/lib/private/be-BOP /var/lib/private/be-BOP-mongodb /var/lib/private/phoenixd; do
        run_privileged test -d "$base" || continue
        # `-mindepth 1 -maxdepth 1 -type d` — plain child dirs only.
        # Follow symlinks (-L) because /var/lib/be-BOP-mongodb/<tid> is
        # itself a symlink managed by systemd's StateDirectory.
        run_privileged find -L "$base" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' 2>/dev/null \
            | grep -E '^[a-z0-9][a-z0-9-]*$' || true
    done
}

# nginx vhosts and their stale backups.
#   - bebop-<id>.conf                    (active or sitting in sites-available)
#   - bebop-<id>.conf.bak.<timestamp>    (dropped by fix-acme-vhosts.sh or
#                                         other bulk operations; often left
#                                         behind indefinitely)
discover_nginx_ids() {
    local d
    for d in /etc/nginx/sites-available /etc/nginx/sites-enabled; do
        run_privileged test -d "$d" || continue
        run_privileged find "$d" -mindepth 1 -maxdepth 1 \
            \( -name 'bebop-*.conf' -o -name 'bebop-*.conf.bak.*' \) \
            -printf '%f\n' 2>/dev/null \
            | sed -nE 's/^bebop-(.+)\.conf(\.bak\..+)?$/\1/p' \
            | grep -v '^$' || true
    done
}

# Cert names owned by the infra layer (not tenants). Anything in this
# list must be excluded from discover_le_ids — otherwise find-orphans
# extracts an "id" from them, doesn't find that id in the tenant
# registry, treats it as orphan, and `certbot delete` wipes an infra
# cert. Observed on 2026-07 when bebop-deploy-api got shredded, breaking
# nginx -t for every subsequent add-tenant.sh.
#
# Names here should exactly match the `--cert-name` values used in
# host-bootstrap.sh's certbot invocations. Keep in sync manually — a
# dedicated helper wasn't worth the plumbing for the ~3 known names.
readonly INFRA_LE_CERT_IDS=$'deploy-api'

# Let's Encrypt live dirs: bebop-<id> and bebop-<id>-s3.
# `deploy-api` (and any other name in INFRA_LE_CERT_IDS) is excluded
# because those live-dirs are bebop-<name> per host-bootstrap.sh
# convention but the "name" is infrastructure, not a tenant id.
discover_le_ids() {
    run_privileged test -d /etc/letsencrypt/live || return 0
    run_privileged find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d \
        -name 'bebop-*' -printf '%f\n' 2>/dev/null \
        | sed -nE 's/^bebop-(.+)$/\1/p' \
        | sed -E 's/-s3$//' \
        | grep -v '^$' \
        | grep -vxF "$INFRA_LE_CERT_IDS" \
        || true
}

# Union of all discovered ids, deduplicated and sorted.
discover_all_ids() {
    {
        discover_systemd_ids
        discover_dir_ids
        discover_nginx_ids
        discover_le_ids
    } | sort -u
}

# Every id present in the registry, regardless of status. We intentionally
# treat archived tenants as "still known" — their port may have been
# released, but any residual on-disk state is a matter for remove-tenant.
registry_known_ids() {
    if [[ ! -f "$REGISTRY_PATH" ]]; then
        return 0
    fi
    awk -F'\t' 'NR>1 && $1!="" {print $1}' "$REGISTRY_PATH" | sort -u
}

# True iff at least one concrete artefact exists on disk / in systemd for
# this id. Belt-and-suspenders check applied after registry diff: if a
# discovery source turned up an id but nothing concrete remains, we skip
# it — reporting an id with no listed artefact wastes the operator's time.
_id_has_artefact() {
    local id="$1" u d
    # systemd — is-enabled catches instances enabled via .wants/ symlinks
    # (which list-unit-files misses for template instances). is-active
    # catches transient/running units not enabled at boot.
    for u in "bebop@${id}.service" "phoenixd@${id}.service" "mongod@${id}.service"; do
        if run_privileged systemctl is-enabled --quiet "$u" 2>/dev/null; then
            return 0
        fi
        if run_privileged systemctl is-active --quiet "$u" 2>/dev/null; then
            return 0
        fi
    done
    for d in "/etc/be-BOP/${id}" "/etc/be-BOP-mongodb/${id}" "/etc/phoenixd/${id}" \
             "/var/lib/be-BOP/${id}" "/var/lib/be-BOP-mongodb/${id}" "/var/lib/phoenixd/${id}" \
             "/var/lib/private/be-BOP/${id}" "/var/lib/private/be-BOP-mongodb/${id}" "/var/lib/private/phoenixd/${id}" \
             "/etc/nginx/sites-available/bebop-${id}.conf" \
             "/etc/nginx/sites-enabled/bebop-${id}.conf" \
             "/etc/letsencrypt/live/bebop-${id}" \
             "/etc/letsencrypt/live/bebop-${id}-s3"; do
        if run_privileged test -e "$d"; then
            return 0
        fi
    done
    # nginx stale backups
    if [[ -n "$(run_privileged find /etc/nginx/sites-available -maxdepth 1 \
                    -name "bebop-${id}.conf.bak.*" -print -quit 2>/dev/null)" ]]; then
        return 0
    fi
    return 1
}

# Print the sorted list of orphan ids on stdout.
list_orphans() {
    local all known candidates id
    all=$(discover_all_ids)
    known=$(registry_known_ids)
    if [[ -z "$all" ]]; then
        return 0
    fi
    if [[ -z "$known" ]]; then
        candidates="$all"
    else
        # comm -23: lines only in file 1
        candidates=$(comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$known"))
    fi
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if _id_has_artefact "$id"; then
            printf '%s\n' "$id"
        fi
    done <<< "$candidates"
}

# === Reporting ==========================================================

# Print the artefacts detected for a single id.
_report_one() {
    local id="$1"
    printf '  %s\n' "$id"

    # systemd — is-enabled catches template instances enabled via .wants/
    # symlinks (which list-unit-files misses). We report both states so an
    # operator can tell "just a stray symlink" from "actually running".
    local u enabled active
    for u in "bebop@${id}.service" "phoenixd@${id}.service" "mongod@${id}.service"; do
        enabled=$(run_privileged systemctl is-enabled "$u" 2>/dev/null || true)
        active=$(run_privileged systemctl is-active "$u" 2>/dev/null || true)
        if [[ -n "$enabled" || -n "$active" ]]; then
            printf '    systemd:     %s (enabled=%s active=%s)\n' \
                "$u" "${enabled:-none}" "${active:-none}"
        fi
    done

    local d
    for d in "/etc/be-BOP/${id}" "/etc/be-BOP-mongodb/${id}" "/etc/phoenixd/${id}" \
             "/var/lib/be-BOP/${id}" "/var/lib/be-BOP-mongodb/${id}" "/var/lib/phoenixd/${id}" \
             "/var/lib/private/be-BOP/${id}" "/var/lib/private/be-BOP-mongodb/${id}" "/var/lib/private/phoenixd/${id}"; do
        if run_privileged test -e "$d"; then
            printf '    dir:         %s\n' "$d"
        fi
    done

    local v
    for v in "/etc/nginx/sites-available/bebop-${id}.conf" \
             "/etc/nginx/sites-enabled/bebop-${id}.conf"; do
        if run_privileged test -e "$v"; then
            printf '    nginx:       %s\n' "$v"
        fi
    done

    # Stale .bak.<timestamp> nginx files.
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        printf '    nginx.bak:   %s\n' "$f"
    done < <(run_privileged find /etc/nginx/sites-available -maxdepth 1 \
                    -name "bebop-${id}.conf.bak.*" 2>/dev/null || true)

    local c
    for c in "bebop-${id}" "bebop-${id}-s3"; do
        if run_privileged test -d "/etc/letsencrypt/live/${c}"; then
            printf '    LE cert:     %s\n' "$c"
        fi
    done
}

do_report() {
    local orphans
    orphans=$(list_orphans)
    if [[ -z "$orphans" ]]; then
        echo "No orphans detected."
        return 0
    fi
    echo "Orphans found on this host (present as artefacts, absent from registry):"
    echo
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        _report_one "$id"
        echo
    done <<< "$orphans"
    cat <<EOF
Purge one:  find-orphans.sh --purge <tenant_id>
Purge all:  find-orphans.sh --purge-all

Not touched by this script: DNS records, Garage buckets, Uptime Kuma monitors.
EOF
}

# === Purge ==============================================================

_dry_run_prefix() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[dry-run] '
    fi
}

_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run: $*"
        return 0
    fi
    "$@"
}

# Stop + disable one systemd unit. Ignores errors: our goal is to converge
# to "gone", any state along the way is acceptable.
#
# We check is-enabled/is-active because list-unit-files does NOT match
# template instances enabled via a .wants/ symlink — so a purge that only
# looks at list-unit-files would leave orphan symlinks in place, which
# is exactly the failure mode this script exists to fix. We also fall
# back to a direct symlink lookup for the (rare) case where the symlink
# points to a template that no longer exists on disk.
_stop_disable_unit() {
    local unit="$1"
    local is_enabled=false is_active=false
    if run_privileged systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        is_enabled=true
    fi
    if run_privileged systemctl is-active --quiet "$unit" 2>/dev/null; then
        is_active=true
    fi
    if [[ "$is_enabled" == "true" || "$is_active" == "true" ]]; then
        log_info "disable+stop ${unit} (enabled=${is_enabled} active=${is_active})"
        _run run_privileged systemctl disable --now "$unit" 2>/dev/null || true
        return 0
    fi
    # Neither enabled nor active — check for orphan .wants/ symlink whose
    # target may have vanished (systemctl would then reject is-enabled).
    local sym
    sym=$(run_privileged find /etc/systemd/system -maxdepth 3 -name "$unit" \
              -type l -print -quit 2>/dev/null || true)
    if [[ -n "$sym" ]]; then
        log_info "rm orphan systemd symlink ${sym}"
        _run run_privileged rm -f "$sym"
        return 0
    fi
    log_debug "unit ${unit} not present"
}

_remove_nginx_vhost() {
    local id="$1"
    local enabled="/etc/nginx/sites-enabled/bebop-${id}.conf"
    local available="/etc/nginx/sites-available/bebop-${id}.conf"
    local touched=false
    if run_privileged test -L "$enabled" || run_privileged test -f "$enabled"; then
        log_info "rm nginx symlink ${enabled}"
        _run run_privileged rm -f "$enabled"
        touched=true
    fi
    if run_privileged test -f "$available"; then
        log_info "rm nginx vhost ${available}"
        _run run_privileged rm -f "$available"
        touched=true
    fi
    # Stale backups left by fix-acme-vhosts.sh or other bulk edits. Only
    # dropped for orphan tenants (registered ids never reach _purge_one).
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        log_info "rm nginx backup ${f}"
        _run run_privileged rm -f "$f"
        touched=true
    done < <(run_privileged find /etc/nginx/sites-available -maxdepth 1 \
                    -name "bebop-${id}.conf.bak.*" 2>/dev/null || true)
    if [[ "$touched" == "true" && "$DRY_RUN" != "true" ]]; then
        if run_privileged nginx -t 2>/dev/null; then
            run_privileged systemctl reload nginx || true
        else
            log_warn "nginx -t failed after removing vhost bebop-${id}; leaving reload to operator"
        fi
    fi
}

_delete_le_cert() {
    local name="$1"
    if run_privileged test -d "/etc/letsencrypt/live/${name}"; then
        log_info "certbot delete ${name}"
        _run run_privileged certbot delete --cert-name "$name" --non-interactive 2>/dev/null || true
    fi
}

_purge_dirs() {
    local id="$1" u d
    # systemctl clean --what=state handles the StateDirectory pair
    # (public symlink + /var/lib/private/<StateDirectory>) atomically —
    # this is the primitive systemd exposes for exactly this job.
    for u in "bebop@${id}.service" "phoenixd@${id}.service" "mongod@${id}.service"; do
        _run run_privileged systemctl clean --what=state "$u" 2>/dev/null || true
    done
    # Belt-and-suspenders: explicit rm on both the symlink and the private
    # target, plus the /etc/… config dirs (not managed by StateDirectory).
    for d in "/etc/be-BOP/${id}" "/etc/be-BOP-mongodb/${id}" "/etc/phoenixd/${id}" \
             "/var/lib/be-BOP/${id}" "/var/lib/be-BOP-mongodb/${id}" "/var/lib/phoenixd/${id}" \
             "/var/lib/private/be-BOP/${id}" "/var/lib/private/be-BOP-mongodb/${id}" "/var/lib/private/phoenixd/${id}"; do
        if run_privileged test -e "$d"; then
            log_info "rm -rf ${d}"
            _run run_privileged rm -rf "$d"
        fi
    done
}

_confirm_purge() {
    local id="$1"
    if [[ "$ASSUME_YES" == "true" ]]; then
        return 0
    fi
    if [[ "$RUN_NON_INTERACTIVE" == "true" ]]; then
        die "purge in --non-interactive mode requires --yes"
    fi
    echo
    echo "About to PURGE orphan '${id}'."
    echo "This will disable systemd units, drop nginx vhost, delete LE certs,"
    echo "and rm -rf /etc/be-BOP/${id}, /var/lib/be-BOP/${id},"
    echo "/var/lib/be-BOP-mongodb/${id} on this host."
    read -r -p "Type '${id}' to confirm: " reply
    if [[ "$reply" != "$id" ]]; then
        die "confirmation mismatch — purge aborted"
    fi
}

_purge_one() {
    local id="$1"

    # Refuse ids that are registered: use remove-tenant.sh for those.
    local status
    status=$(registry_get_status "$id" 2>/dev/null || echo "absent")
    if [[ "$status" != "absent" ]]; then
        die "refusing to purge '${id}': it is a registered tenant (status=${status}). Use remove-tenant.sh instead."
    fi

    # Sanity — never rm -rf a suspiciously-empty or wildcard-like id.
    if [[ -z "$id" || "$id" == "*" || "$id" == "." || "$id" == ".." ]]; then
        die "refusing to purge invalid id: '${id}'"
    fi
    if [[ ! "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "refusing to purge id with unexpected characters: '${id}'"
    fi

    _confirm_purge "$id"

    log_info "purging orphan '${id}'"
    _stop_disable_unit "bebop@${id}.service"
    _stop_disable_unit "phoenixd@${id}.service"
    _stop_disable_unit "mongod@${id}.service"
    _remove_nginx_vhost "$id"
    _delete_le_cert "bebop-${id}"
    _delete_le_cert "bebop-${id}-s3"
    # Drop the mail-relay's stored credentials for this tenant. Without
    # this, a purged+recreated tenant would inherit the previous relay
    # row → phase_mail_relay would skip → runtimeConfig.smtp would not be
    # re-seeded with a fresh per-tenant password. mail-relay-ctl.sh is
    # itself idempotent (no-op when the row doesn't exist).
    if command -v mail-relay-ctl.sh >/dev/null 2>&1; then
        _run run_privileged mail-relay-ctl.sh delete "$id" 2>/dev/null || true
    fi
    _purge_dirs "$id"
    log_info "orphan '${id}' purged"
}

do_purge_one() {
    local id="$1"
    # We do not lock the registry here — purging touches on-host artefacts
    # for ids NOT in the registry, so no row-level concurrency concern.
    # A concurrent add-tenant would race on the same id, but that is the
    # operator's decision (and add-tenant would fail its own preflight).
    _purge_one "$id"
}

do_purge_all() {
    local orphans
    orphans=$(list_orphans)
    if [[ -z "$orphans" ]]; then
        echo "No orphans detected — nothing to purge."
        return 0
    fi
    # One confirmation covers the whole batch when --yes.
    if [[ "$ASSUME_YES" != "true" ]]; then
        if [[ "$RUN_NON_INTERACTIVE" == "true" ]]; then
            die "purge-all in --non-interactive mode requires --yes"
        fi
        echo "About to PURGE the following orphans:"
        printf '  %s\n' $orphans
        read -r -p "Type 'PURGE-ALL' to confirm: " reply
        if [[ "$reply" != "PURGE-ALL" ]]; then
            die "confirmation mismatch — purge-all aborted"
        fi
        # Skip per-tenant confirmation once the batch is acknowledged.
        ASSUME_YES=true
    fi
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        _purge_one "$id" || log_warn "purge of '${id}' returned non-zero; continuing"
    done <<< "$orphans"
}

# === Main ===============================================================
main() {
    require_privileges
    registry_init

    case "$MODE" in
        report)     do_report ;;
        purge)      do_purge_one "$TARGET_ID" ;;
        purge-all)  do_purge_all ;;
        *)          die "unreachable: unknown mode '$MODE'" ;;
    esac
}

main "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# fix-http2-vhosts.sh — one-shot removal of HTTP/2 from the nginx vhosts
# already installed by the multi-tenant tooling.
#
# Why this script exists:
# CVE-2026-123633 and CVE-2026-123007, disclosed on 2026-11-18, let a remote
# client crash an nginx worker or run code, without authentication, when
# nginx accepts HTTP/2. Until that date every template of this tooling
# declared `listen 443 ssl http2`, and the hosts run the nginx of the
# distribution, which has no fixed package yet. The templates no longer
# enable HTTP/2, but a vhost is only rendered when its tenant is created
# or re-applied: the vhosts already on disk keep it until this script runs.
#
# HTTP/2 is a property of the listening socket, not of a server block: one
# remaining `listen 443 ... http2` keeps it on for every vhost sharing that
# address. The script therefore patches all the vhosts it knows in one run
# and then fails loudly if nginx still declares HTTP/2 anywhere.
#
# This script:
#   1. Scans /etc/nginx/sites-available/ for the tenant vhosts
#      (bebop-*.conf) and the host vhosts (netdata.conf, kuma.conf,
#      deploy.conf).
#   2. Drops the `http2` parameter of their `listen` directives, and turns
#      `http2 on;` into `http2 off;`.
#   3. Runs `nginx -t`; on failure, restores every file and stops.
#   4. Restarts nginx. Not a reload: former workers would keep serving the
#      connections already open, as configured before.
#   5. Checks the configuration nginx loads for a remaining HTTP/2 listener.
#
# Idempotent: a vhost without HTTP/2 is left untouched, and nginx is only
# restarted when a file changed. host-bootstrap.sh runs it on every pass,
# so updating the tooling is enough; it can also be run by hand.
#
# Usage:
#   sudo fix-http2-vhosts.sh                    # patch + nginx restart
#   sudo fix-http2-vhosts.sh --dry-run          # diff only, no writes
#   sudo fix-http2-vhosts.sh --rollback <stamp> # restore the *.bak.<stamp> files

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="fix-http2-vhosts"

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

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

VHOST_DIR=/etc/nginx/sites-available
# Only the vhosts this tooling writes. Hidden files, editor swap files and
# earlier backups never match these patterns.
PATTERNS=( 'bebop-*.conf' netdata.conf kuma.conf deploy.conf )
# A `listen` directive carrying the http2 parameter, or `http2 on;`.
readonly HTTP2_RE='^[[:space:]]*(listen[[:space:]][^;#]*[[:space:]]http2([[:space:];]|$)|http2[[:space:]]+on[[:space:]]*;)'
DRY_RUN=false
ROLLBACK_STAMP=""

usage() {
    cat <<EOF
fix-http2-vhosts.sh — remove HTTP/2 from the nginx vhosts already installed
by the multi-tenant tooling (one-shot, for CVE-2026-123633 and CVE-2026-123007).

Usage:
  fix-http2-vhosts.sh [--dry-run] [--verbose] [-h|--help]
  fix-http2-vhosts.sh --rollback <stamp>

Options:
  --dry-run           show unified diff for each vhost that would be patched
  --rollback <stamp>  restore the vhosts saved as <vhost>.bak.<stamp> by an
                      earlier run, then restart nginx
  --verbose           verbose logging
  -h, --help          this help
EOF
}

while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --rollback)
            if [[ -z "${2:-}" ]]; then
                echo "${SCRIPT_NAME}: --rollback needs the stamp of a previous run" >&2
                exit 2
            fi
            ROLLBACK_STAMP="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "${SCRIPT_NAME}: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
export VERBOSE DRY_RUN

# Print the vhost with HTTP/2 removed.
strip_http2() {
    sed -E \
        -e '/^[[:space:]]*listen[[:space:]]/ s/^([^;#]*)[[:space:]]http2([[:space:];]|$)/\1\2/' \
        -e 's/^([[:space:]]*)http2[[:space:]]+on[[:space:]]*;/\1http2 off;/' \
        "$1"
}

# Number of HTTP/2 listeners in the configuration nginx actually loads.
count_loaded_http2() {
    run_privileged nginx -T 2>/dev/null | grep -cE "$HTTP2_RE" || true
}

restart_nginx() {
    log_info "nginx -t OK — restarting nginx"
    run_privileged systemctl restart nginx
}

run_rollback() {
    shopt -s nullglob
    local backups=( "$VHOST_DIR"/*.bak."$ROLLBACK_STAMP" )
    if (( ${#backups[@]} == 0 )); then
        die "no backup ${VHOST_DIR}/*.bak.${ROLLBACK_STAMP} — nothing to restore"
    fi
    local b f
    for b in "${backups[@]}"; do
        f="${b%.bak."$ROLLBACK_STAMP"}"
        run_privileged install -m 0644 "$b" "$f"
        log_info "restored: $(basename "$f")"
    done
    if ! run_privileged nginx -t; then
        die "nginx -t failed on the restored vhosts — nginx NOT restarted, still running its previous configuration"
    fi
    restart_nginx
    log_info "rollback done: ${#backups[@]} vhost(s) restored, $(count_loaded_http2) HTTP/2 listener(s) loaded"
}

main() {
    if [[ "$DRY_RUN" != "true" ]] && ! run_privileged true 2>/dev/null; then
        die "must run as root or with passwordless sudo"
    fi
    if ! command -v nginx >/dev/null 2>&1; then
        die "nginx not installed — nothing to migrate"
    fi
    if [[ ! -d "$VHOST_DIR" ]]; then
        die "vhost dir not found: $VHOST_DIR"
    fi

    if [[ -n "$ROLLBACK_STAMP" ]]; then
        run_rollback
        return 0
    fi

    shopt -s nullglob
    local files=() p f
    for p in "${PATTERNS[@]}"; do
        # The pattern must expand here; a literal name stays as is, hence -f.
        for f in "$VHOST_DIR"/$p; do
            [[ -f "$f" ]] && files+=( "$f" )
        done
    done
    log_info "found ${#files[@]} vhost(s) managed by the tooling under ${VHOST_DIR}"

    local patched=0 skipped=0
    local touched=()
    local ts; ts=$(date +%Y%m%d%H%M%S)

    local tmp
    for f in "${files[@]}"; do
        # Vhosts are world-readable (0644): read them directly, so that a
        # sudo failure can never pass for "no HTTP/2 here".
        if ! grep -qE "$HTTP2_RE" "$f"; then
            log_debug "skip (no HTTP/2): $(basename "$f")"
            skipped=$((skipped + 1))
            continue
        fi

        tmp=$(mktemp)
        strip_http2 "$f" > "$tmp"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "--- would patch: $f"
            diff -u "$f" "$tmp" || true
            rm -f "$tmp"
            patched=$((patched + 1))
            continue
        fi

        run_privileged cp -p "$f" "${f}.bak.${ts}"
        run_privileged install -m 0644 "$tmp" "$f"
        rm -f "$tmp"
        touched+=( "$f" )
        patched=$((patched + 1))
        log_info "patched: $(basename "$f") (backup: $(basename "$f").bak.${ts})"
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "dry-run summary: ${patched} would be patched, ${skipped} without HTTP/2"
        return 0
    fi

    if (( ${#touched[@]} > 0 )); then
        log_info "running nginx -t..."
        if ! run_privileged nginx -t; then
            log_error "nginx -t FAILED — rolling back all patches"
            for f in "${touched[@]}"; do
                run_privileged install -m 0644 "${f}.bak.${ts}" "$f"
                log_info "rolled back: $(basename "$f")"
            done
            die "nginx -t failed; vhosts rolled back; nginx not restarted"
        fi
        restart_nginx
    fi

    log_info "summary: ${patched} patched, ${skipped} without HTTP/2"
    if (( patched > 0 )); then
        log_info "to undo: sudo fix-http2-vhosts.sh --rollback ${ts}"
    fi

    local remaining
    remaining=$(count_loaded_http2)
    if (( remaining > 0 )); then
        log_error "nginx still loads ${remaining} HTTP/2 listener(s), outside the vhosts this tooling manages:"
        # -R, not -r: sites-enabled holds symlinks.
        { run_privileged grep -RIlE "$HTTP2_RE" /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null || true; } \
            | while IFS= read -r f; do log_error "  $(readlink -f "$f")"; done
        die "HTTP/2 is still on: one remaining listener keeps it for every vhost on the same address"
    fi
    log_info "no HTTP/2 listener left in the configuration nginx loads"
}

main "$@"

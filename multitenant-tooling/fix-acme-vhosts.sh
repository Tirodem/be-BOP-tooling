#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# fix-acme-vhosts.sh — one-shot backport of the ACME HTTP-01 webroot block
# into existing per-tenant nginx vhosts.
#
# Why this script exists:
# Until template revision 2026062101, nginx-tenant-main.conf.tmpl assumed
# the host catch-all default vhost would serve /.well-known/acme-challenge/
# for renewals. That assumption only holds when no other server matches —
# but per-tenant vhosts declare `server_name <fqdn>` on `listen 80`, so
# nginx routes port-80 requests for that FQDN to the tenant vhost, NOT
# to the default. The redirect-to-HTTPS then sends certbot's renewal
# challenge to the be-BOP app, which returns HTML — Let's Encrypt
# rejects with "unauthorized". Initial issuance works because the
# tenant vhost doesn't exist yet (phase_certificate runs before
# phase_nginx); the bug only manifests at renewal time (~60 days later).
#
# This script:
#   1. Scans /etc/nginx/sites-available/bebop-*.conf
#   2. For each vhost that lacks the acme webroot location, inserts it
#      just before `location / { return 30N https://... }` in the HTTP
#      redirect server block.
#   3. Runs `nginx -t`; on success, reloads nginx.
#
# Idempotent. Harmless on internal (DNS-01) tenants: the block is dead
# code there but doesn't conflict with anything.
#
# Usage:
#   sudo fix-acme-vhosts.sh             # patch + nginx reload
#   sudo fix-acme-vhosts.sh --dry-run   # diff only, no writes

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="fix-acme-vhosts"

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
PATTERN='bebop-*.conf'
DRY_RUN=false

usage() {
    cat <<EOF
fix-acme-vhosts.sh — backport ACME HTTP-01 webroot location into existing
per-tenant nginx vhosts (one-shot migration for template rev < 2026062101).

Usage:
  fix-acme-vhosts.sh [--dry-run] [--verbose] [-h|--help]

Options:
  --dry-run    show unified diff for each vhost that would be patched
  --verbose    verbose logging
  -h, --help   this help
EOF
}

while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "${SCRIPT_NAME}: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
export VERBOSE DRY_RUN

# Inject the acme location block right before the `location /` line of the
# server block that contains a `return 30N https:` (= the HTTP-01 redirect
# block). awk exits 2 if no such block is found, 0 if injected, 3 if
# already-patched (caller checks before invoking).
inject_acme_block() {
    awk '
        BEGIN { injected=0 }
        {
            buf[NR] = $0
        }
        END {
            for (i = 1; i <= NR; i++) {
                line = buf[i]
                # Detect "location / {" — possibly with extra whitespace.
                if (!injected && line ~ /^[[:space:]]+location[[:space:]]+\/[[:space:]]*\{[[:space:]]*$/) {
                    # Peek at next line: must be a 301/302/307/308 to https.
                    if (i + 1 <= NR && buf[i+1] ~ /return[[:space:]]+30[12478][[:space:]]+https:/) {
                        # Preserve the leading indent of the location line.
                        match(line, /^[[:space:]]+/)
                        indent = substr(line, 1, RLENGTH)
                        print indent "location ^~ /.well-known/acme-challenge/ {"
                        print indent "    root /var/lib/letsencrypt;"
                        print indent "    default_type \"text/plain\";"
                        print indent "}"
                        print ""
                        injected=1
                    }
                }
                print line
            }
            exit (injected ? 0 : 2)
        }
    ' "$1"
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

    shopt -s nullglob
    local files=( "$VHOST_DIR"/$PATTERN )
    if (( ${#files[@]} == 0 )); then
        log_info "no tenant vhosts under ${VHOST_DIR}/${PATTERN} — nothing to do"
        return 0
    fi
    log_info "found ${#files[@]} tenant vhost(s) under ${VHOST_DIR}"

    local patched=0 skipped=0 unmatched=0
    local touched=()
    local ts; ts=$(date +%Y%m%d%H%M%S)

    local f tmp
    for f in "${files[@]}"; do
        if run_privileged grep -q 'location \^~ /.well-known/acme-challenge/' "$f"; then
            log_info "skip (already patched): $(basename "$f")"
            skipped=$((skipped + 1))
            continue
        fi

        tmp=$(mktemp)
        if ! inject_acme_block "$f" > "$tmp"; then
            log_warn "no HTTP-01 redirect block found in $(basename "$f") — leaving untouched"
            rm -f "$tmp"
            unmatched=$((unmatched + 1))
            continue
        fi

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
        log_info "dry-run summary: ${patched} would be patched, ${skipped} already patched, ${unmatched} unmatched"
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
            die "nginx -t failed; vhosts rolled back; no reload performed"
        fi
        log_info "nginx -t OK — reloading nginx"
        run_privileged systemctl reload nginx
    fi

    log_info "summary: ${patched} patched, ${skipped} already patched, ${unmatched} unmatched"
    if (( patched > 0 )); then
        log_info "next: verify a previously-failing tenant with:"
        log_info "  sudo certbot renew --cert-name bebop-<tenant> --dry-run"
    fi
}

main "$@"

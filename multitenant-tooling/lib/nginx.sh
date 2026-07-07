# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# nginx.sh — helpers shared between host-bootstrap.sh and add-tenant.sh
# (and anywhere else the tooling runs `nginx -t`).
#
# Public:
#   nginx_quarantine_broken_vhosts  — remove sites-enabled/ symlinks that
#                                     reference a missing SSL cert OR
#                                     that make `nginx -t` fail on
#                                     syntax. Idempotent. Loud warns.
#
# Source AFTER lib/log.sh and lib/sudo.sh.

[[ -n "${_BEBOP_NGINX_SOURCED:-}" ]] && return 0
readonly _BEBOP_NGINX_SOURCED=1

# Any callable that predates this refactor may still call the private
# `_nginx_quarantine_broken_vhosts` name — keep the alias so we don't
# have to touch every caller in a single commit.
_nginx_quarantine_broken_vhosts() { nginx_quarantine_broken_vhosts "$@"; }

# nginx_quarantine_broken_vhosts
#
# Two passes, both non-fatal on a healthy host:
#
#   1. Scan sites-enabled/ for symlinks whose target references an
#      ssl_certificate*.pem path that doesn't exist on disk. Typical
#      after an interrupted migrate-tenant.sh or a manual `certbot
#      delete`. Remove the symlink from sites-enabled/ (keep the file
#      in sites-available/ for forensics). Log a WARN per quarantined
#      vhost naming the missing path.
#
#   2. Run `nginx -t`. If it fails, extract the first
#      /etc/nginx/sites-enabled/<basename> mentioned in the error
#      (nginx signals the file it was reading when it choked), quarantine
#      it, retry. Bounded by the number of vhosts present at entry.
#
# Rationale: infra updates and tenant onboarding must NEVER be blocked
# by broken state left behind by another tenant. An operator with one
# busted vhost should still be able to deploy the fix for whatever
# broke it.
#
# Skipped entirely when DRY_RUN=true.
nginx_quarantine_broken_vhosts() {
    local sites_enabled=/etc/nginx/sites-enabled
    [[ -d "$sites_enabled" ]] || return 0
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi

    local link vhost_file cert_path missing_cert quarantined=0
    for link in "$sites_enabled"/*; do
        [[ -L "$link" || -f "$link" ]] || continue
        vhost_file=$(readlink -f "$link" 2>/dev/null || echo "$link")
        [[ -r "$vhost_file" ]] || continue
        missing_cert=""
        while IFS= read -r cert_path; do
            [[ -z "$cert_path" ]] && continue
            if [[ ! -e "$cert_path" ]]; then
                missing_cert="$cert_path"
                break
            fi
        done < <(grep -E '^[[:space:]]*ssl_certificate(_key)?[[:space:]]+' "$vhost_file" \
                 | awk '{print $2}' \
                 | tr -d ';')
        if [[ -n "$missing_cert" ]]; then
            log_warn "nginx: quarantining vhost '$(basename "$link")' — cert '${missing_cert}' missing on disk. Symlink removed from sites-enabled; file preserved in sites-available for reference."
            run_privileged rm -f "$link"
            (( quarantined++ ))
        fi
    done
    if (( quarantined > 0 )); then
        log_warn "nginx: ${quarantined} cert-missing vhost(s) quarantined"
    fi

    local max_iter iter=0 nginx_err offender
    max_iter=$(find "$sites_enabled" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
    while (( iter < max_iter )); do
        nginx_err=$(run_privileged nginx -t 2>&1) && return 0
        offender=$(printf '%s\n' "$nginx_err" \
            | grep -oE "${sites_enabled}/[^ :]+" \
            | head -1)
        if [[ -z "$offender" || ! -e "$offender" ]]; then
            log_warn "nginx -t failed but couldn't identify a sites-enabled/ vhost to quarantine; full error follows"
            printf '%s\n' "$nginx_err" | while IFS= read -r line; do log_warn "nginx: ${line}"; done
            return 0
        fi
        log_warn "nginx: quarantining vhost '$(basename "$offender")' — syntax rejected by nginx -t."
        run_privileged rm -f "$offender"
        (( iter++ ))
        (( quarantined++ ))
    done
    if (( quarantined > 0 )); then
        log_warn "nginx: total ${quarantined} vhost(s) quarantined (cert-missing + syntax combined)"
    fi
}

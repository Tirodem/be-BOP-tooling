#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# install.sh — one-shot bootstrap for the be-BOP multi-tenant tooling.
#
# Mirrors the v1 wizard distribution model (single command, blank VPS to
# ready-to-configure host). Only requires curl and tar (both shipped in
# Debian 12 base) — no pre-installation of git or anything else needed.
#
# Usage (PoC — TODO: switch to https://be-bop.io/saas/install.sh once configured):
#   curl -sfSL \
#     https://raw.githubusercontent.com/Tirodem/be-BOP-tooling/multitenant-poc/multitenant-tooling/install.sh \
#     -o install.sh \
#     && sudo bash ./install.sh
#
# What it does, in order:
#   1. Verifies curl and tar are available; refuses to run as non-root.
#   2. Downloads the multitenant-poc branch tarball from GitHub.
#   3. Installs the multitenant-tooling/ subtree to /opt/be-BOP-tooling/.
#   4. Reconciles /etc/be-BOP-tooling/secrets.env:
#      - Absent → seed from the template.
#      - Present but no required credentials filled → replace from the
#        current template (a backup is taken first). This handles the
#        "the template was updated" case cleanly.
#      - Present with credentials filled → prompt the operator:
#          [r]eset = backup to .bak.<ts> + replace from template (start over)
#          [k]eep  = resume with the existing values (default in --non-interactive)
#        Non-interactive operators can force [r] via --reset-secrets.
#   5. Runs host-bootstrap.sh:
#      - Fresh / reset path → with --defer-secrets, then opens secrets.env
#        in $EDITOR / nano (if a TTY is attached). Operator must re-run
#        host-bootstrap.sh after filling in secrets.
#      - Resume path → without --defer-secrets, DNS provider connectivity is checked
#        immediately. No editor is opened; the existing secrets.env is used.
#   6. Prints next-step commands tailored to the path taken.
#
# Re-run safe: every step is idempotent.
#
# Extra args are forwarded to host-bootstrap.sh (e.g. --dry-run, --verbose).
# install.sh-specific flags:
#   --reset-secrets   Force the reset path (back up + re-seed) even when
#                     the existing secrets.env has filled values. Useful in
#                     --non-interactive runs where the default is "keep".
#   --clean           Wipe /opt/be-BOP-tooling AND /etc/be-BOP-tooling
#                     before running the fresh install. Refuses if
#                     /var/lib/be-BOP/tenants.tsv has any tenant row —
#                     you must remove-tenant.sh them first, or use
#                     --force-clean to override (destroys the registry).
#   --force-clean     Same as --clean but skips the tenant safeguard.
#                     NEVER use this on a host that serves live tenants.
# NOTE — what --clean does NOT touch:
#   /var/lib/be-BOP/           (tenant state, ports, releases)
#   /var/lib/be-BOP-mongodb/   (per-tenant mongod data)
#   /var/lib/phoenixd/         (Lightning wallet seeds)
#   /etc/systemd/system/       (installed unit files — host-bootstrap
#                                re-installs them cleanly)
#   apt-installed packages     (Node, Garage, phoenixd, certbot, etc.)
#   /etc/letsencrypt/          (issued certs)

set -eEuo pipefail

readonly REPO="${BEBOP_TOOLING_REPO:-Tirodem/be-BOP-tooling}"
readonly REF="${BEBOP_TOOLING_REF:-multitenant-poc}"
readonly INSTALL_DIR="${BEBOP_TOOLING_INSTALL_DIR:-/opt/be-BOP-tooling}"
readonly SECRETS_DIR="/etc/be-BOP-tooling"
readonly SECRETS_FILE="${SECRETS_DIR}/secrets.env"

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARN: %s\n' "$*" >&2; }
die()  { printf '[install] FATAL: %s\n' "$*" >&2; exit 1; }

# Filter install.sh-specific flags out of the args before forwarding to
# host-bootstrap.sh, which does not understand them.
RESET_SECRETS=false
NON_INTERACTIVE_FLAG=false
CLEAN_INSTALL=false
FORCE_CLEAN=false
forwarded_args=()
for a in "$@"; do
    case "$a" in
        --reset-secrets)   RESET_SECRETS=true ;;
        --clean)           CLEAN_INSTALL=true ;;
        --force-clean)     CLEAN_INSTALL=true; FORCE_CLEAN=true ;;
        --non-interactive) NON_INTERACTIVE_FLAG=true; forwarded_args+=("$a") ;;
        *)                 forwarded_args+=("$a") ;;
    esac
done

# 1. Prerequisites — curl and tar should be in Debian base; bail with a
# clear message if they aren't.
for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "'$tool' is required but not installed (apt-get install -y $tool)"
done

if (( EUID != 0 )); then
    die "this installer must run as root (use sudo)"
fi

# 1.5. --clean : wipe previous install artefacts so the operator can
# restart from a truly blank state without having to `rm -rf` anything by
# hand. Refuses when the tenant registry has any row, unless
# --force-clean overrides — the registry is what tracks live merchants,
# blowing it away with tenants running would strand them.
if [[ "$CLEAN_INSTALL" == "true" ]]; then
    if [[ "$FORCE_CLEAN" != "true" && -f /var/lib/be-BOP/tenants.tsv ]]; then
        # Header is line 1; any additional line = at least one tenant.
        row_count=$(($(wc -l < /var/lib/be-BOP/tenants.tsv) - 1))
        if (( row_count > 0 )); then
            die "--clean refused: /var/lib/be-BOP/tenants.tsv has ${row_count} tenant row(s). Remove them via remove-tenant.sh first, or pass --force-clean if you really want to wipe the registry (destructive)."
        fi
    fi
    log "--clean: wiping ${INSTALL_DIR} and ${SECRETS_DIR}..."
    rm -rf "$INSTALL_DIR" "$SECRETS_DIR"
    if [[ "$FORCE_CLEAN" == "true" && -f /var/lib/be-BOP/tenants.tsv ]]; then
        warn "--force-clean: also wiping /var/lib/be-BOP/tenants.tsv"
        rm -f /var/lib/be-BOP/tenants.tsv
    fi
fi

# 2. Download + extract tarball.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "Downloading be-BOP multi-tenant tooling (${REPO}@${REF})..."
url="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"
if ! curl -sfSL --connect-timeout 10 --max-time 300 -o "${tmp}/tooling.tar.gz" "$url"; then
    die "could not download ${url}"
fi
tar -xz -C "$tmp" -f "${tmp}/tooling.tar.gz"

# The archive top-level dir is repo-${ref-with-slashes-replaced}; locate it
# defensively rather than assuming the exact name.
extracted_root=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d ! -name '.*' \
    -name "be-BOP-tooling-*" | head -n1)
if [[ -z "$extracted_root" || ! -d "${extracted_root}/multitenant-tooling" ]]; then
    die "tarball did not contain a multitenant-tooling/ directory"
fi

# 3. Install to /opt/be-BOP-tooling/.
log "Installing tooling to ${INSTALL_DIR}..."
install -d -m 0755 "$INSTALL_DIR"
cp -a "${extracted_root}/multitenant-tooling/." "${INSTALL_DIR}/"
chmod 0755 \
    "${INSTALL_DIR}/host-bootstrap.sh" \
    "${INSTALL_DIR}/add-tenant.sh" \
    "${INSTALL_DIR}/remove-tenant.sh" \
    "${INSTALL_DIR}/migrate-tenant.sh" \
    "${INSTALL_DIR}/migrate-mongo-auth.sh" \
    "${INSTALL_DIR}/upgrade-tenant.sh" \
    "${INSTALL_DIR}/upgrade-all.sh" \
    "${INSTALL_DIR}/list-tenants.sh" \
    "${INSTALL_DIR}/find-orphans.sh" \
    "${INSTALL_DIR}/mail-relay-ctl.sh" \
    "${INSTALL_DIR}/mail-relay-upstream-sync.sh" \
    "${INSTALL_DIR}/tenant-cli.sh" \
    "${INSTALL_DIR}/gh-rate-limit.sh" \
    "${INSTALL_DIR}/certbot-renew-check.sh" \
    "${INSTALL_DIR}/backup-tenants.sh" \
    "${INSTALL_DIR}/backup-tooling.sh" \
    "${INSTALL_DIR}/restore-tenant.sh" \
    "${INSTALL_DIR}/restore-tooling.sh" \
    "${INSTALL_DIR}/freeze-tenant.sh" \
    "${INSTALL_DIR}/bebop-exit-handler.sh" \
    "${INSTALL_DIR}/bebop-exit-worker.sh" \
    "${INSTALL_DIR}/bebop-mongo-preflight.sh" \
    "${INSTALL_DIR}/tooling-mail-relay-preflight.sh" \
    "${INSTALL_DIR}/tenant-reaper.sh" \
    "${INSTALL_DIR}/fix-acme-vhosts.sh" \
    "${INSTALL_DIR}/install.sh" 2>/dev/null || true
# Hooks must be executable for certbot --manual-{auth,cleanup}-hook
# to invoke them; safety net if the tarball didn't preserve +x.
chmod 0755 "${INSTALL_DIR}/hooks/"*.sh 2>/dev/null || true

# 4. Reconcile secrets.env: fresh / reset / resume.
install -d -m 0700 "$SECRETS_DIR"
TEMPLATE_PATH="${INSTALL_DIR}/templates/secrets.env.example"
RESUME_FROM_EXISTING=false

# Did the operator fill in any required credential?
# Source the file in a subshell so quoted-empty values (`KEY=""`) resolve
# to actual empty strings — a grep `.+` would count the quotes as "value"
# and falsely report the file as filled, which then routes install.sh to
# the keep/reset prompt instead of the resume-with-defer-secrets path.
secrets_have_values() {
    (
        set -a
        # shellcheck disable=SC1090
        source "$SECRETS_FILE" 2>/dev/null || exit 1
        set +a
        [[ -n "${OVH_APPLICATION_KEY:-}${OVH_APPLICATION_SECRET:-}${OVH_CONSUMER_KEY:-}${INFOMANIAK_API_TOKEN:-}${BACKUP_ENCRYPTION_KEY:-}" ]]
    )
}

reset_secrets_to_template() {
    local ts bak
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    bak="${SECRETS_FILE}.bak.${ts}"
    if [[ -f "$SECRETS_FILE" ]]; then
        cp -a "$SECRETS_FILE" "$bak"
        chmod 600 "$bak"
        log "Backed up current secrets.env to $bak"
    fi
    install -m 0600 "$TEMPLATE_PATH" "$SECRETS_FILE"
    log "Reset $SECRETS_FILE from template"
}

if [[ ! -f "$SECRETS_FILE" ]]; then
    install -m 0600 "$TEMPLATE_PATH" "$SECRETS_FILE"
    log "Created $SECRETS_FILE (mode 0600)"
elif ! secrets_have_values; then
    log "$SECRETS_FILE has no required credentials filled in; replacing with the current template"
    reset_secrets_to_template
else
    # Existing secrets.env has values worth preserving.
    if [[ "$RESET_SECRETS" == "true" ]]; then
        log "--reset-secrets given; backing up and resetting from template"
        reset_secrets_to_template
    elif [[ -t 0 && -t 1 && "$NON_INTERACTIVE_FLAG" != "true" ]]; then
        echo
        echo "${SECRETS_FILE} already has credentials filled in."
        echo "  [r] Reset  — backup to ${SECRETS_FILE}.bak.<ts>, replace with"
        echo "              the template, then re-edit interactively."
        echo "  [k] Keep   — resume the setup using the existing values"
        echo "              (skips the editor; DNS provider credentials checked now)."
        read -r -p "Choose [r/k] (default: k): " choice
        case "${choice:-k}" in
            r|R) reset_secrets_to_template ;;
            *)   log "Keeping existing $SECRETS_FILE"
                 RESUME_FROM_EXISTING=true ;;
        esac
    else
        log "Non-interactive mode: keeping existing $SECRETS_FILE (use --reset-secrets to override)"
        RESUME_FROM_EXISTING=true
    fi
fi

# 5. Run host-bootstrap.sh. Resume path skips --defer-secrets so DNS
# provider connectivity is verified immediately (dns_provider_ping via
# lib/dns_provider.sh, backed by the selected DNS_PROVIDER).
if [[ "$RESUME_FROM_EXISTING" == "true" ]]; then
    log "Running host-bootstrap.sh (resume — no --defer-secrets)..."
    "${INSTALL_DIR}/host-bootstrap.sh" "${forwarded_args[@]+"${forwarded_args[@]}"}"
else
    log "Running host-bootstrap.sh --defer-secrets..."
    "${INSTALL_DIR}/host-bootstrap.sh" --defer-secrets "${forwarded_args[@]+"${forwarded_args[@]}"}"
fi

# 6. Open secrets.env in the operator's editor — only when starting from a
# fresh / reset template (resume path skips this; the file is already filled).
if [[ "$RESUME_FROM_EXISTING" != "true" ]]; then
    editor="${EDITOR:-nano}"
    if [[ -t 0 && -t 1 ]] && command -v "$editor" >/dev/null 2>&1; then
        log "Opening ${SECRETS_FILE} in ${editor}..."
        "$editor" "$SECRETS_FILE"
    else
        warn "non-interactive shell — edit ${SECRETS_FILE} manually before continuing"
    fi
fi

# 7. Final instructions.
cat <<EOF

==========================================================================
  be-BOP multi-tenant tooling installed
==========================================================================

  Tooling:    ${INSTALL_DIR}/
  Secrets:    ${SECRETS_FILE}

EOF

if [[ "$RESUME_FROM_EXISTING" == "true" ]]; then
    cat <<EOF
SETUP RESUMED with the existing secrets.env. host-bootstrap.sh ran
without --defer-secrets, so DNS provider connectivity has been validated and the
certbot DNS provider credentials file is in place.

NEXT STEPS:

  1. Add your first tenant:
       sudo add-tenant.sh tenant1 --admin-email merchant@example.com

Documentation: ${INSTALL_DIR}/README.md
==========================================================================
EOF
else
    cat <<EOF
NEXT STEPS:

  1. (If you skipped editing secrets above) edit secrets:
       sudo \$EDITOR ${SECRETS_FILE}

  2. Finalise the host bootstrap (idempotent — only runs the
     DNS-provider credential steps that were deferred):
       sudo ${INSTALL_DIR}/host-bootstrap.sh

  3. Add your first tenant:
       sudo add-tenant.sh tenant1 --admin-email merchant@example.com

Documentation: ${INSTALL_DIR}/README.md
==========================================================================
EOF
fi

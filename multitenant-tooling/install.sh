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
#                     before running the fresh install. Requires an
#                     interactive TTY and a typed "WIPE" (case
#                     sensitive) confirmation. Refuses if
#                     /var/lib/be-BOP/tenants.tsv has any tenant row —
#                     you must remove-tenant.sh them first, or use
#                     --force-clean to override (destroys the registry).
#   --force-clean     Same as --clean but skips BOTH the tenant
#                     safeguard AND the WIPE confirmation. Also skips
#                     the confirmation under --non-interactive. NEVER
#                     use --force-clean on a host that serves live
#                     tenants.
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

    # Hard confirmation — --clean wipes /opt and /etc. Even after the
    # tenants-tsv safeguard above, this is a destructive operation that
    # will nuke any local edits to secrets.env, deploy-default.json,
    # kuma-admin.env, etc. Long typed phrase (case sensitive) so a typo,
    # muscle-memory Enter, or accidental clipboard paste can't trigger
    # it. --force-clean OR --non-interactive skips the prompt (scripting
    # path — operator explicitly opted into the destructive behaviour
    # via a flag).
    # Ask what to do with secrets.env — the one file that's expensive
    # to re-create (API tokens, encryption key, notification setup).
    # Default: keep. Operator can explicitly opt into wiping it.
    KEEP_SECRETS=true
    if [[ "$FORCE_CLEAN" != "true" && "$NON_INTERACTIVE_FLAG" != "true" ]]; then
        readonly CLEAN_CONFIRMATION_PHRASE="I KNOW WHAT I WANT BUDDY TRUST ME"
        if [[ -t 0 && -t 1 ]]; then
            echo
            warn "About to WIPE:"
            warn "  ${INSTALL_DIR}"
            warn "  ${SECRETS_DIR}"
            warn "This will delete secrets.env, deploy-default.json, kuma-admin.env,"
            warn "netdata-admin.env, deploy-api.env, and any other local ops files."
            echo
            read -r -p "Type '${CLEAN_CONFIRMATION_PHRASE}' (case sensitive) to confirm: " confirm
            if [[ "$confirm" != "$CLEAN_CONFIRMATION_PHRASE" ]]; then
                die "--clean aborted (confirmation did not match)"
            fi

            echo
            echo "  [k] Keep secrets.env — backup + restore after wipe (default)"
            echo "  [w] Wipe secrets.env too — full nuke, edit from template on re-run"
            read -r -p "Choose [k/w] (default: k): " sec_choice
            case "${sec_choice:-k}" in
                w|W) KEEP_SECRETS=false ;;
                *)   KEEP_SECRETS=true ;;
            esac
        else
            die "--clean requires an interactive TTY for confirmation; use --force-clean or --non-interactive to skip the prompt (destructive!)"
        fi
    fi

    # If we're keeping secrets.env, stash it in a tmp location before
    # the wipe, restore it after. Simpler than adding conditional rm
    # patterns.
    KEEP_TMP=""
    if [[ "$KEEP_SECRETS" == "true" && -f "$SECRETS_FILE" ]]; then
        KEEP_TMP=$(mktemp)
        cp -a "$SECRETS_FILE" "$KEEP_TMP"
        log "--clean: staging ${SECRETS_FILE} for restore after wipe"
    fi

    log "--clean: wiping ${INSTALL_DIR} and ${SECRETS_DIR}..."
    rm -rf "$INSTALL_DIR" "$SECRETS_DIR"

    if [[ -n "$KEEP_TMP" ]]; then
        install -d -m 0700 "$SECRETS_DIR"
        install -m 0600 "$KEEP_TMP" "$SECRETS_FILE"
        rm -f "$KEEP_TMP"
        log "--clean: restored ${SECRETS_FILE}"
    fi
    # Also wipe Uptime Kuma docker state — an existing container from a
    # previous install carries admin creds inside its /app/data volume.
    # host-bootstrap's step_setup_kuma_admin dies with "Kuma has been
    # initialized" otherwise. Silent no-op if docker isn't installed yet
    # (very fresh VDS) or if the container was never created.
    if command -v docker >/dev/null 2>&1; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'bebop-uptime-kuma'; then
            log "--clean: removing bebop-uptime-kuma container"
            docker rm -f bebop-uptime-kuma >/dev/null 2>&1 || true
        fi
    fi
    if [[ -d /var/lib/uptime-kuma ]]; then
        log "--clean: wiping /var/lib/uptime-kuma"
        rm -rf /var/lib/uptime-kuma
    fi
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
    # BACKUP_ENCRYPTION_KEY is now auto-seeded (see seed_backup_encryption_key),
    # so it's always present on a fresh install — checking it would falsely
    # mark the file as "filled". Only look at provider creds, which the
    # operator MUST enter by hand.
    (
        set -a
        # shellcheck disable=SC1090
        source "$SECRETS_FILE" 2>/dev/null || exit 1
        set +a
        [[ -n "${OVH_APPLICATION_KEY:-}${OVH_APPLICATION_SECRET:-}${OVH_CONSUMER_KEY:-}${INFOMANIAK_API_TOKEN:-}" ]]
    )
}

# Auto-populate BACKUP_ENCRYPTION_KEY when it's still the empty
# placeholder from the template. Pure crypto material — nothing the
# operator can meaningfully choose, so we skip forcing them to run
# `openssl rand -hex 32` and paste the value by hand. Preserves any
# manually-set value (sed only matches the exact empty form).
seed_backup_encryption_key() {
    if grep -qE '^BACKUP_ENCRYPTION_KEY=""$' "$SECRETS_FILE"; then
        local gen
        gen=$(openssl rand -hex 32)
        sed -i "s|^BACKUP_ENCRYPTION_KEY=\"\"|BACKUP_ENCRYPTION_KEY=\"${gen}\"|" "$SECRETS_FILE"
        log "Auto-generated BACKUP_ENCRYPTION_KEY (32 bytes hex)"
    fi
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
    seed_backup_encryption_key
    log "Reset $SECRETS_FILE from template"
}

DEPLOY_DEFAULT_TEMPLATE="${INSTALL_DIR}/templates/deploy-default.json.example"
DEPLOY_DEFAULT_FILE="${SECRETS_DIR}/deploy-default.json"
# Install deploy-default.json if missing. Never overwrite — operator's
# deploy-time choices (feature toggles + per-source profiles) stay
# across install.sh re-runs. mode 0644 because it's NOT secret.
if [[ ! -f "$DEPLOY_DEFAULT_FILE" ]]; then
    install -m 0644 "$DEPLOY_DEFAULT_TEMPLATE" "$DEPLOY_DEFAULT_FILE"
    log "Created $DEPLOY_DEFAULT_FILE (mode 0644) — edit to change per-tenant defaults + per-source profiles"
fi
# Legacy deploy-default.env from the pre-JSON draft: harmless once ignored
# by add-tenant.sh, but rm it here to keep /etc clean and prevent operator
# confusion about which file is authoritative.
if [[ -f "${SECRETS_DIR}/deploy-default.env" ]]; then
    warn "removing legacy ${SECRETS_DIR}/deploy-default.env (superseded by deploy-default.json)"
    rm -f "${SECRETS_DIR}/deploy-default.env"
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
    install -m 0600 "$TEMPLATE_PATH" "$SECRETS_FILE"
    seed_backup_encryption_key
    log "Created $SECRETS_FILE (mode 0600)"
fi

# --- Reconciling secrets.env ---
# Three real-world scenarios:
#   (a) File is EMPTY (just created from template — fresh VDS, or
#       --clean, or aborted previous run). There's nothing to "keep"
#       or "reset" against — just open the editor and let the operator
#       fill it. No pointless prompt.
#   (b) File is FILLED (previous install left real values). Ask
#       [k]eep / [r]eset / [e]dit — the operator has something worth
#       preserving.
#   (c) Non-interactive OR --reset-secrets: short-circuit without
#       prompting.
if [[ "$RESET_SECRETS" == "true" ]]; then
    log "--reset-secrets given; backing up and resetting from template"
    reset_secrets_to_template
    # After reset we fall through to (a) below — file is empty again.
fi

if secrets_have_values; then
    # Scenario (b): filled file, prompt keep/reset/edit.
    if [[ -t 0 && -t 1 && "$NON_INTERACTIVE_FLAG" != "true" ]]; then
        echo
        echo "${SECRETS_FILE} already has credentials filled in."
        echo "  [k] Keep as-is — bootstrap with existing values (DNS ping runs)"
        echo "  [e] Edit       — open the file in \$EDITOR / nano before bootstrap"
        echo "  [r] Reset      — backup + replace with the empty template + edit"
        read -r -p "Choose [k/e/r] (default: k): " choice
        case "${choice:-k}" in
            e|E)
                editor="${EDITOR:-nano}"
                if command -v "$editor" >/dev/null 2>&1; then
                    log "Opening ${SECRETS_FILE} in ${editor}..."
                    "$editor" "$SECRETS_FILE"
                else
                    warn "editor '${editor}' not found — proceeding with current values"
                fi
                ;;
            r|R)
                reset_secrets_to_template
                ;;
            *)
                log "Keeping existing $SECRETS_FILE"
                ;;
        esac
    else
        log "Non-interactive mode: keeping existing $SECRETS_FILE as-is (use --reset-secrets to override)"
    fi
fi

# After potential prompt or reset — if the file is EMPTY now, open the
# editor directly (scenario (a)). --non-interactive skips this and
# proceeds in --defer-secrets. The final warn at the end catches the
# empty state so the operator sees "please fill and re-run".
if ! secrets_have_values; then
    if [[ -t 0 && -t 1 && "$NON_INTERACTIVE_FLAG" != "true" ]]; then
        editor="${EDITOR:-nano}"
        if command -v "$editor" >/dev/null 2>&1; then
            echo
            log "Opening ${SECRETS_FILE} in ${editor} — fill in DNS_PROVIDER, BEBOP_DNS_ZONE, then save + exit"
            "$editor" "$SECRETS_FILE"
        else
            warn "editor '${editor}' not found — proceeding with empty file"
        fi
    fi
fi

# Decide bootstrap mode: filled after all the above → normal (DNS ping
# runs), still empty → defer.
if secrets_have_values; then
    RESUME_FROM_EXISTING=true
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

# 6. Final state — if secrets.env is still empty (operator chose keep +
# defer, or --non-interactive proceeded on an empty file), print the
# explicit "fichier foireux, merci de modifier" warning so it lands as
# the LAST thing on the terminal, hard to miss.
if ! secrets_have_values; then
    echo
    warn "==========================================================================="
    warn "  ${SECRETS_FILE} has EMPTY required credentials."
    warn "  Fill DNS_PROVIDER, BEBOP_DNS_ZONE, and the provider-specific keys, then"
    warn "  re-run: sudo bash /opt/be-BOP-tooling/install.sh"
    warn "  (or continue directly: sudo /opt/be-BOP-tooling/host-bootstrap.sh)"
    warn "==========================================================================="
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

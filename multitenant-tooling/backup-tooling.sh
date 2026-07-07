#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# backup-tooling.sh — encrypted backup of the VDS-wide tooling state.
#
# Complements backup-tenants.sh (which handles per-tenant merchant data
# — Mongo dump, Garage bucket, phoenixd seed). This one covers the
# host-wide state needed to rebuild a VDS from scratch:
#
#   - mongodump of the tooling database (bebop_tooling on mongod@tooling:
#     mail-relay's tenants creds, send_log, alert_state — anything a future
#     host-wide tool stores in the same instance)
#   - /var/lib/be-BOP/tenants.tsv              (tenant registry)
#   - /etc/be-BOP-tooling/secrets.env          (provider credentials)
#   - /etc/be-BOP/<tenant>/config.env          (per-tenant node env)
#   - /etc/be-BOP-mongodb/<tenant>/port.env    (per-tenant mongod port)
#   - /etc/be-BOP-mongodb/tooling/port.env     (tooling mongod port)
#   - /etc/phoenixd/<tenant>/port.env          (per-tenant phoenixd port)
#
# Bundled into a single .zip, encrypted with BACKUP_ENCRYPTION_KEY from
# secrets.env (openssl AES-256-CBC + PBKDF2), uploaded to
# SFTP_REMOTE_PATH/tooling/<YYYYMMDDTHHMMSSZ>.zip.enc. Same convention as
# backup-tenants.sh so restore uses the same code path.
#
# NOT included on purpose:
#   - Per-tenant Mongo / Garage / phoenixd data — those are backup-tenants
#     territory (they need mongodump / rclone / consistency guarantees
#     that this fast lightweight backup doesn't try to provide).
#   - Let's Encrypt live/archive/renewal dirs — re-issuable at will.
#   - systemd unit files — reinstalled by host-bootstrap.sh.

set -eEuo pipefail

readonly SCRIPT_NAME="backup-tooling"

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
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
DRY_RUN=false
RUN_NON_INTERACTIVE=false

usage() {
    cat <<EOF
backup-tooling.sh — encrypted backup of the VDS tooling state.

Usage:
  backup-tooling.sh [--secrets-file <path>] [--dry-run] [--non-interactive]
EOF
}

while (( $# )); do
    case "$1" in
        --secrets-file)     SECRETS_FILE="$2"; shift 2 ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --non-interactive)  RUN_NON_INTERACTIVE=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

require_privileges
[[ -f "$SECRETS_FILE" ]] || die "secrets file not found: ${SECRETS_FILE}"
# shellcheck disable=SC1090
source "$SECRETS_FILE"

for var in SFTP_HOST SFTP_USER SFTP_PASSWORD_OR_KEY_PATH SFTP_REMOTE_PATH BACKUP_ENCRYPTION_KEY; do
    [[ -z "${!var:-}" ]] && die "${var} missing in ${SECRETS_FILE}"
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

_run() { if [[ "$DRY_RUN" == "true" ]]; then log_info "[dry-run] $*"; else "$@"; fi; }

collect_stage() {
    local stage="${WORK}/stage"
    install -d -m 0755 "$stage"
    # Config files staged under their absolute paths so tar/zip preserves
    # the layout — a restore drops each back where it came from.
    local src
    for src in \
            /var/lib/be-BOP/tenants.tsv \
            /etc/be-BOP-tooling/secrets.env; do
        if [[ -f "$src" ]]; then
            install -d -m 0755 "${stage}$(dirname "$src")"
            install -m 0600 "$src" "${stage}${src}"
        fi
    done
    # Per-tenant + tooling dirs (config.env / port.env only — merchant
    # data lives in backup-tenants).
    local base
    for base in /etc/be-BOP /etc/be-BOP-mongodb /etc/phoenixd; do
        [[ -d "$base" ]] || continue
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            install -d -m 0755 "${stage}${d}"
            find "$d" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null \
                | xargs -0 -r -I{} install -m 0600 "{}" "${stage}{}"
        done < <(find "$base" -mindepth 1 -maxdepth 1 -type d)
    done
    # mongodump of the tooling database (mailrelay-mongodb, port
    # 27100 by design). Dump lands under a stable relative path inside
    # the archive so restore-tooling can find it.
    install -d -m 0755 "${stage}/mongodump-tooling"
    mongodump --quiet --port 27100 --db bebop_tooling \
        --out "${stage}/mongodump-tooling" \
        || die "mongodump of bebop_tooling failed"
    printf '%s' "$stage"
}

log_info "backup-tooling: starting (dry-run=${DRY_RUN})"
STAGE=$(collect_stage)
ARCHIVE="${WORK}/tooling-${TS}.zip"
_run bash -c "cd '${STAGE}' && zip -qr '${ARCHIVE}' ."

# Encrypt with BACKUP_ENCRYPTION_KEY.
ENC="${ARCHIVE}.enc"
_run bash -c "openssl enc -aes-256-cbc -pbkdf2 -salt -in '${ARCHIVE}' -out '${ENC}' -pass pass:'${BACKUP_ENCRYPTION_KEY}'"
rm -f "$ARCHIVE"

# Upload via sftp — same auth pattern as backup-tenants (password or key).
REMOTE="${SFTP_REMOTE_PATH%/}/tooling"
BATCH=$(mktemp)
cat > "$BATCH" <<EOF
-mkdir ${REMOTE}
cd ${REMOTE}
put ${ENC}
bye
EOF
if [[ -f "$SFTP_PASSWORD_OR_KEY_PATH" ]]; then
    _run sftp -oBatchMode=no -oStrictHostKeyChecking=accept-new \
        -i "$SFTP_PASSWORD_OR_KEY_PATH" -P "${SFTP_PORT:-22}" \
        -b "$BATCH" "${SFTP_USER}@${SFTP_HOST}"
else
    _run sshpass -p "$SFTP_PASSWORD_OR_KEY_PATH" \
        sftp -oBatchMode=no -oStrictHostKeyChecking=accept-new \
        -P "${SFTP_PORT:-22}" -b "$BATCH" "${SFTP_USER}@${SFTP_HOST}"
fi
rm -f "$BATCH"

log_info "backup-tooling: uploaded ${REMOTE}/$(basename "$ENC")"
notify_success \
    "[be-BOP tooling] backup-tooling OK" \
    "VDS tooling state backed up to ${REMOTE}/$(basename "$ENC")."

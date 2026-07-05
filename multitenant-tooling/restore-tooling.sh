#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# restore-tooling.sh — inverse of backup-tooling.sh.
#
# Pulls a specific encrypted tooling archive from SFTP, decrypts with
# BACKUP_ENCRYPTION_KEY, and writes each file back to its original
# location. NOT a full disaster recovery on its own — use with
# host-bootstrap.sh (packages, systemd units) and restore-tenant.sh
# (per-tenant Mongo / Garage / phoenixd data) to fully rebuild a VDS.
#
# Usage:
#   restore-tooling.sh --archive tooling-20260618T140000Z.zip.enc
#   restore-tooling.sh --latest    # picks the most recent archive under
#                                    ${SFTP_REMOTE_PATH}/tooling/
#
# Safety: any destination file that already exists is backed up to
# <path>.bak.<ts> before being overwritten, so a bad restore never
# clobbers current state silently.

set -eEuo pipefail

readonly SCRIPT_NAME="restore-tooling"

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

SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
ARCHIVE_NAME=""
PICK_LATEST=false
DRY_RUN=false

usage() {
    cat <<EOF
restore-tooling.sh — pull + decrypt + restore a tooling backup archive.

Usage:
  restore-tooling.sh --archive <name>   # explicit archive filename
  restore-tooling.sh --latest           # most recent archive under SFTP
  restore-tooling.sh --dry-run          # show what would be restored
EOF
}

while (( $# )); do
    case "$1" in
        --archive)      ARCHIVE_NAME="$2"; shift 2 ;;
        --latest)       PICK_LATEST=true; shift ;;
        --secrets-file) SECRETS_FILE="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage; exit 0 ;;
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
[[ -z "$ARCHIVE_NAME" && "$PICK_LATEST" != "true" ]] \
    && die "one of --archive <name> or --latest is required"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REMOTE_DIR="${SFTP_REMOTE_PATH%/}/tooling"

_sftp_run() {
    local batch="$1"
    if [[ -f "$SFTP_PASSWORD_OR_KEY_PATH" ]]; then
        sftp -oBatchMode=no -oStrictHostKeyChecking=accept-new \
            -i "$SFTP_PASSWORD_OR_KEY_PATH" -P "${SFTP_PORT:-22}" \
            -b "$batch" "${SFTP_USER}@${SFTP_HOST}"
    else
        sshpass -p "$SFTP_PASSWORD_OR_KEY_PATH" \
            sftp -oBatchMode=no -oStrictHostKeyChecking=accept-new \
            -P "${SFTP_PORT:-22}" -b "$batch" "${SFTP_USER}@${SFTP_HOST}"
    fi
}

if [[ "$PICK_LATEST" == "true" ]]; then
    log_info "restore-tooling: listing ${REMOTE_DIR} to pick latest archive"
    BATCH=$(mktemp)
    cat > "$BATCH" <<EOF
cd ${REMOTE_DIR}
ls -1
bye
EOF
    ARCHIVE_NAME=$(_sftp_run "$BATCH" 2>/dev/null \
        | grep -E 'tooling-[0-9TZ]+\.zip\.enc$' | sort | tail -n1)
    rm -f "$BATCH"
    [[ -z "$ARCHIVE_NAME" ]] && die "restore-tooling: no archives found under ${REMOTE_DIR}"
    log_info "restore-tooling: picked ${ARCHIVE_NAME}"
fi

# Pull the archive.
BATCH=$(mktemp)
cat > "$BATCH" <<EOF
cd ${REMOTE_DIR}
get ${ARCHIVE_NAME} ${WORK}/${ARCHIVE_NAME}
bye
EOF
_sftp_run "$BATCH"
rm -f "$BATCH"

DEC="${WORK}/tooling.zip"
openssl enc -d -aes-256-cbc -pbkdf2 -in "${WORK}/${ARCHIVE_NAME}" \
    -out "$DEC" -pass pass:"$BACKUP_ENCRYPTION_KEY"

# Unpack into an isolated dir, then rsync into place with per-file
# backups so any conflict leaves a rollback file.
STAGE="${WORK}/stage"
install -d -m 0755 "$STAGE"
unzip -qq "$DEC" -d "$STAGE"

TS=$(date -u +%Y%m%dT%H%M%SZ)
count=0
# Config files are laid out with their absolute paths inside the archive.
# The mongodump sits at ${STAGE}/mongodump-tooling/ and gets restored
# separately with mongorestore below.
while IFS= read -r -d '' src; do
    dst="${src#${STAGE}}"
    [[ "$dst" == /mongodump-tooling/* ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would restore ${dst}"
        continue
    fi
    install -d -m 0755 "$(dirname "$dst")"
    if [[ -f "$dst" ]]; then
        cp -a "$dst" "${dst}.bak.${TS}"
    fi
    install -m 0600 "$src" "$dst"
    (( count++ )) || true
done < <(find "$STAGE" -type f -print0)

# mongorestore of the tooling database. Uses --drop so a partial restore
# doesn't leave stale documents alongside the restored ones. Assumes
# mongod@tooling is already up (host-bootstrap sets it up before this
# script would ever be run in a rebuild sequence).
if [[ -d "${STAGE}/mongodump-tooling/bebop_tooling" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would mongorestore bebop_tooling from ${STAGE}/mongodump-tooling"
    else
        mongorestore --quiet --port 27100 --drop \
            --nsInclude 'bebop_tooling.*' \
            "${STAGE}/mongodump-tooling" \
            || die "mongorestore of bebop_tooling failed"
        log_info "restore-tooling: bebop_tooling restored via mongorestore"
    fi
fi

log_info "restore-tooling: restored ${count} config file(s) from ${ARCHIVE_NAME} (backups suffix .bak.${TS})"

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# restore-tenant.sh — restore a single tenant from a backup-tenants.sh
# archive on SFTP. One-shot per tenant (no --all equivalent — a restore
# is a destructive operation that benefits from explicit per-tenant intent).
#
# Pre-conditions:
#   - The tenant already exists and is `active` in the registry. If you
#     want to "rehydrate" a tenant on a fresh VDS, run add-tenant.sh first,
#     then restore-tenant.sh.
#   - SFTP credentials in /etc/be-BOP-tooling/secrets.env match the host
#     that holds the backup.
#
# Default encryption mode: BACKUP_ENCRYPTION_KEY from secrets.env. Use
# --passphrase <pw> for backups taken with backup-tenants.sh --for-handoff.
#
# Pre-flight safety net: by default the script triggers a backup-tenants
# run of the target tenant BEFORE touching anything, so an erroneous
# restore is rollback-able. --no-pre-backup skips that step (useful when
# the current state is already broken and a backup would fail anyway).

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="restore-tenant"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "restore-tenant: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"
# shellcheck source=lib/healthcheck.sh
source "$BEBOP_TOOLING_LIB_DIR/healthcheck.sh"
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# === CLI ================================================================
SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
TENANT_ID=""
FTP_PATH=""
PASSPHRASE=""
PRE_BACKUP=true
RUN_NON_INTERACTIVE=false
DRY_RUN=false
HEALTHCHECK_RETRIES=15
HEALTHCHECK_INTERVAL=2

usage() {
    cat <<EOF
restore-tenant.sh — restore a tenant from a backup archive on SFTP.

Usage:
  restore-tenant.sh <tenant_id> <ftp_path> [options]

Arguments:
  <tenant_id>            tenant to restore (must already exist and be active)
  <ftp_path>             path of the .zip.enc on SFTP, RELATIVE to
                         SFTP_REMOTE_PATH (e.g. "qa-tirodem/20260612T115918Z.zip.enc")

Options:
  --passphrase <pw>      passphrase for backups taken with --for-handoff
                         (default: BACKUP_ENCRYPTION_KEY from secrets.env)
  --no-pre-backup        skip the safety-net backup taken before the restore
                         (use when the tenant is already broken and a backup
                         would fail anyway)
  --non-interactive      skip the destructive-operation confirmation prompt
  --secrets-file <path>  override default ${SECRETS_FILE}
  --dry-run              print actions without executing
  -h, --help

The restore replaces, on the live VDS:
  - the tenant's MongoDB content (drop + mongorestore)
  - the tenant's Garage bucket content (rclone sync from backup)
  - phoenixd seed.dat + phoenix.conf
  - /etc/be-BOP/<tenant>/config.env (preserving operator customs below
    the scissor marker)

bebop@<tenant> and phoenixd@<tenant> are stopped during the restore and
restarted at the end. mongod@<tenant> stays up (mongorestore needs it).
EOF
}

while (( $# )); do
    case "$1" in
        --passphrase)      PASSPHRASE="$2"; shift 2 ;;
        --no-pre-backup)   PRE_BACKUP=false; shift ;;
        --non-interactive) RUN_NON_INTERACTIVE=true; shift ;;
        --secrets-file)    SECRETS_FILE="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)
            if [[ -z "$TENANT_ID" ]]; then
                TENANT_ID="$1"
            elif [[ -z "$FTP_PATH" ]]; then
                FTP_PATH="$1"
            else
                die "unexpected positional arg: $1"
            fi
            shift
            ;;
    esac
done

[[ -z "$TENANT_ID" ]] && { usage; die "tenant_id is required"; }
[[ -z "$FTP_PATH" ]]  && { usage; die "<ftp_path> is required"; }

BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
export BEBOP_TOOLING_TENANT_ID

require_privileges
if [[ ! -f "$SECRETS_FILE" ]]; then
    die "secrets file not found: ${SECRETS_FILE}"
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

[[ -z "${SFTP_HOST:-}" ]]            && die "SFTP_HOST not set in ${SECRETS_FILE}"
[[ -z "${SFTP_USER:-}" ]]            && die "SFTP_USER not set in ${SECRETS_FILE}"
[[ -z "${SFTP_REMOTE_PATH:-}" ]]      && die "SFTP_REMOTE_PATH not set in ${SECRETS_FILE}"
[[ -z "${SFTP_PASSWORD_OR_KEY_PATH:-}" ]] && die "SFTP_PASSWORD_OR_KEY_PATH not set in ${SECRETS_FILE}"
if [[ -z "$PASSPHRASE" && -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
    die "no decryption material — provide --passphrase OR set BACKUP_ENCRYPTION_KEY in ${SECRETS_FILE}"
fi

# Decryption material: --passphrase wins if given (handoff-mode backup);
# otherwise BACKUP_ENCRYPTION_KEY (ops-mode backup).
if [[ -z "$PASSPHRASE" ]]; then
    PASSPHRASE="$BACKUP_ENCRYPTION_KEY"
    log_info "decryption: using BACKUP_ENCRYPTION_KEY"
else
    log_info "decryption: using --passphrase (handoff-mode backup expected)"
fi

# === Pre-flight: tenant must exist & be active ===========================
registry_init
status=$(registry_get_status "$TENANT_ID")
case "$status" in
    active) ;;
    absent) die "tenant '${TENANT_ID}' not in registry — run add-tenant.sh first" ;;
    *)      die "tenant '${TENANT_ID}' has status '${status}'; only active tenants can be restored into" ;;
esac

DOMAIN=$(registry_get_field "$TENANT_ID" domain)
MONGO_PORT=$(registry_get_field "$TENANT_ID" mongo_port)
MONGO_DB=$(registry_get_field "$TENANT_ID" mongodb_database)
GARAGE_BUCKET=$(registry_get_field "$TENANT_ID" garage_bucket)

# === Pre-backup safety net ==============================================
if [[ "$PRE_BACKUP" == "true" ]]; then
    log_info "pre-backup: snapshotting current state before restore..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run: backup-tenants.sh ${TENANT_ID}"
    else
        local_backup=$(command -v backup-tenants.sh || echo "${SCRIPT_DIR}/backup-tenants.sh")
        [[ -x "$local_backup" ]] || die "backup-tenants.sh not found / not executable; use --no-pre-backup if you accept the risk"
        if ! "$local_backup" "$TENANT_ID"; then
            die "pre-backup FAILED — aborting restore to preserve current state. Use --no-pre-backup if you accept restoring without rollback safety net."
        fi
        log_info "pre-backup OK — proceeding with restore"
    fi
fi

# === Download from SFTP ==================================================
WORKDIR=$(mktemp -d "/var/tmp/bebop-restore-${TENANT_ID}.XXXXXX")
chmod 0700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

ENC_FILE="${WORKDIR}/backup.zip.enc"
ZIP_FILE="${WORKDIR}/backup.zip"
EXTRACT_DIR="${WORKDIR}/extracted"

log_info "downloading sftp://${SFTP_HOST}${SFTP_REMOTE_PATH}/${FTP_PATH}"
rc_args=(
    --sftp-host "$SFTP_HOST"
    --sftp-port "${SFTP_PORT:-22}"
    --sftp-user "$SFTP_USER"
)
if [[ "$SFTP_PASSWORD_OR_KEY_PATH" == /* ]]; then
    rc_args+=(--sftp-key-file "$SFTP_PASSWORD_OR_KEY_PATH")
else
    obs=$(rclone obscure "$SFTP_PASSWORD_OR_KEY_PATH")
    rc_args+=(--sftp-pass "$obs")
fi
if [[ "$DRY_RUN" != "true" ]]; then
    RCLONE_CONFIG_BACKUP_TYPE=sftp \
    RCLONE_CONFIG_BACKUP_HOST="$SFTP_HOST" \
    RCLONE_CONFIG_BACKUP_PORT="${SFTP_PORT:-22}" \
    RCLONE_CONFIG_BACKUP_USER="$SFTP_USER" \
        rclone "${rc_args[@]}" copyto "backup:${SFTP_REMOTE_PATH}/${FTP_PATH}" "$ENC_FILE" \
        || die "SFTP download failed for ${FTP_PATH}"
fi

# === Decrypt + unzip =====================================================
log_info "decrypting backup..."
if [[ "$DRY_RUN" != "true" ]]; then
    openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -pass "pass:${PASSPHRASE}" \
        -in "$ENC_FILE" -out "$ZIP_FILE" \
        || die "decryption failed — wrong passphrase OR wrong encryption mode (default vs --passphrase)"
    rm -f "$ENC_FILE"
    mkdir -p "$EXTRACT_DIR"
    unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR" \
        || die "unzip failed — corrupted archive?"
    rm -f "$ZIP_FILE"
fi

# === Inspect metadata + plan operations ==================================
HAS_MONGO_DUMP=false
HAS_BUCKET=false
HAS_PHOENIXD=false
HAS_CONFIG=false
if [[ -d "${EXTRACT_DIR}/mongo-dump" ]]; then HAS_MONGO_DUMP=true; fi
if [[ -d "${EXTRACT_DIR}/bucket" ]]; then HAS_BUCKET=true; fi
if [[ -f "${EXTRACT_DIR}/phoenixd/seed.dat" ]]; then HAS_PHOENIXD=true; fi
if [[ -f "${EXTRACT_DIR}/config.env" ]]; then HAS_CONFIG=true; fi

BUCKET_META_COUNT=""
if [[ "$DRY_RUN" != "true" && -r "${EXTRACT_DIR}/metadata.json" ]]; then
    fmt=$(jq -r '.backup_format // "0"' "${EXTRACT_DIR}/metadata.json" 2>/dev/null || echo "0")
    if [[ "$fmt" != "1" ]]; then
        die "backup_format='${fmt}' unsupported by this restore-tenant.sh; expected '1'"
    fi
    BUCKET_META_COUNT=$(jq -r '.bucket_obj_count // ""' "${EXTRACT_DIR}/metadata.json" 2>/dev/null || echo "")
fi

# Compare the archive's declared bucket_obj_count to what's actually in
# ${EXTRACT_DIR}/bucket/. Mismatch OR missing metadata → refuse
# --delete-during (we'd wipe prod bucket content that the archive can't
# put back). Fall back to a NON-destructive sync so the operator can
# still recover partial data, plus a loud warning.
BUCKET_SYNC_MODE="delete-during"
if $HAS_BUCKET; then
    actual_count=$(find "${EXTRACT_DIR}/bucket" -type f 2>/dev/null | wc -l)
    if [[ -z "$BUCKET_META_COUNT" ]]; then
        log_warn "backup metadata has no bucket_obj_count (old format?); switching to NON-destructive rclone sync as a safety net"
        BUCKET_SYNC_MODE="safe"
    elif [[ "$BUCKET_META_COUNT" == "-1" ]]; then
        log_info "backup declares no bucket (tenant was --no-local-s3 at backup time); no bucket restore"
        HAS_BUCKET=false
    elif [[ "$actual_count" != "$BUCKET_META_COUNT" ]]; then
        log_warn "backup bucket integrity check FAILED: metadata declares ${BUCKET_META_COUNT} object(s), archive contains ${actual_count}. Switching to NON-destructive rclone sync — refusing to wipe prod bucket with an incomplete backup."
        BUCKET_SYNC_MODE="safe"
    else
        log_info "backup bucket integrity OK: ${actual_count} object(s) match metadata"
    fi
fi

cat <<EOF

----------------------------------------------------------------------
  restore-tenant — about to execute these destructive operations:
----------------------------------------------------------------------
  Tenant:        ${TENANT_ID}
  Archive:       ${FTP_PATH}
  Pre-backup:    $(if [[ "$PRE_BACKUP" == "true" ]]; then echo "DONE (safety net OK)"; else echo "SKIPPED (--no-pre-backup)"; fi)

  Mongo:         $(if $HAS_MONGO_DUMP; then echo "DROP + mongorestore db=${MONGO_DB}"; else echo "skip (no mongo-dump/ in archive — external Mongo expected)"; fi)
  Garage:        $(if $HAS_BUCKET && [[ -n "$GARAGE_BUCKET" ]]; then echo "rclone sync --delete-during into bucket=${GARAGE_BUCKET}"; elif $HAS_BUCKET; then echo "archive has bucket/ but tenant has no local Garage (--no-local-s3) — skip"; elif [[ -n "$GARAGE_BUCKET" ]]; then echo "archive has no bucket/, but tenant has local Garage — content NOT restored, kept as-is"; else echo "skip (no bucket in archive, no local Garage on tenant)"; fi)
  phoenixd:      $(if $HAS_PHOENIXD; then echo "replace seed.dat + phoenix.conf"; else echo "skip (no phoenixd files in archive)"; fi)
  config.env:    $(if $HAS_CONFIG; then echo "replace (operator customs below >8 preserved)"; else echo "skip (no config.env in archive)"; fi)
----------------------------------------------------------------------
EOF

if [[ "$RUN_NON_INTERACTIVE" != "true" && "$DRY_RUN" != "true" ]]; then
    read -r -p "Continue ? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) die "aborted by operator" ;;
    esac
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] stopping here — no mutations applied"
    exit 0
fi

# === Restore phases ======================================================
log_info "stopping bebop@${TENANT_ID} + phoenixd@${TENANT_ID} (mongod stays up)..."
run_privileged systemctl stop "bebop@${TENANT_ID}.service" 2>/dev/null || true
run_privileged systemctl stop "phoenixd@${TENANT_ID}.service" 2>/dev/null || true

# Mongo
if $HAS_MONGO_DUMP; then
    log_info "mongo: dropping + restoring db=${MONGO_DB}"
    mongo_db_drop "$MONGO_PORT" "$MONGO_DB" || true
    mongo_restore_db "$MONGO_PORT" "$MONGO_DB" "${EXTRACT_DIR}/mongo-dump"
fi

# Garage
if $HAS_BUCKET && [[ -n "$GARAGE_BUCKET" ]]; then
    rc_delete_flag=""
    if [[ "$BUCKET_SYNC_MODE" == "delete-during" ]]; then
        rc_delete_flag="--delete-during"
        log_info "garage: rclone sync --delete-during ${EXTRACT_DIR}/bucket → ${GARAGE_BUCKET}"
    else
        log_warn "garage: rclone sync (NO --delete-during: incomplete backup or missing metadata) ${EXTRACT_DIR}/bucket → ${GARAGE_BUCKET}"
    fi
    key_id=$(run_privileged grep -oP '^S3_KEY_ID=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
    key_secret=$(run_privileged grep -oP '^S3_KEY_SECRET=\K.*' "/etc/be-BOP/${TENANT_ID}/config.env" 2>/dev/null || true)
    if [[ -z "$key_id" || -z "$key_secret" ]]; then
        log_warn "garage: missing S3 creds in config.env — bucket sync SKIPPED"
    else
        RCLONE_CONFIG_GARAGE_TYPE=s3 \
        RCLONE_CONFIG_GARAGE_PROVIDER=Other \
        RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900 \
        RCLONE_CONFIG_GARAGE_REGION=garage \
        RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$key_id" \
        RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$key_secret" \
            rclone --quiet sync ${rc_delete_flag} \
                "${EXTRACT_DIR}/bucket" "garage:${GARAGE_BUCKET}" \
            || die "rclone Garage sync failed"
    fi
fi

# phoenixd
if $HAS_PHOENIXD; then
    log_info "phoenixd: replacing seed.dat + phoenix.conf"
    phoenix_dir="/var/lib/phoenixd/${TENANT_ID}/.phoenix"
    run_privileged install -d -m 0700 "$phoenix_dir"
    run_privileged install -m 0600 "${EXTRACT_DIR}/phoenixd/seed.dat" "${phoenix_dir}/seed.dat"
    # phoenixd@.service uses DynamicUser=yes; the StateDirectory is already
    # chowned to that ephemeral UID. install(1) drops new files as root, so
    # realign owner to the dir or phoenixd can't read its own files post-restore.
    run_privileged chown --reference="$phoenix_dir" "${phoenix_dir}/seed.dat"
    if [[ -f "${EXTRACT_DIR}/phoenixd/phoenix.conf" ]]; then
        run_privileged install -m 0600 "${EXTRACT_DIR}/phoenixd/phoenix.conf" "${phoenix_dir}/phoenix.conf"
        run_privileged chown --reference="$phoenix_dir" "${phoenix_dir}/phoenix.conf"
    fi
fi

# config.env (preserve operator customs below the scissor marker)
if $HAS_CONFIG; then
    log_info "config.env: replacing (preserving operator customs below >8)"
    target="/etc/be-BOP/${TENANT_ID}/config.env"
    marker='# ------------------------ >8 ------------------------'
    existing_custom=""
    if run_privileged test -f "$target"; then
        existing_custom=$(run_privileged sed -n "/^${marker}\$/,\$p" "$target" 2>/dev/null || true)
    fi
    final=$(mktemp)
    # Strip any custom block from the archive's config.env then re-append
    # the CURRENT live custom block (which the operator may have edited
    # since the backup was taken).
    sed "/^${marker}\$/,\$d" "${EXTRACT_DIR}/config.env" > "$final"
    if [[ -n "$existing_custom" ]]; then
        printf '%s\n' "$existing_custom" >> "$final"
    fi
    run_privileged install -m 0640 "$final" "$target"
    rm -f "$final"
fi

# Restart + healthcheck
log_info "starting bebop@${TENANT_ID} + phoenixd@${TENANT_ID}..."
run_privileged systemctl start "phoenixd@${TENANT_ID}.service" 2>/dev/null || true
run_privileged systemctl start "bebop@${TENANT_ID}.service"

log_info "healthcheck https://${DOMAIN}/..."
healthcheck_extra=()
# If the tenant is external-domain (its domain isn't <tenant>.<BEBOP_DNS_ZONE>),
# bypass the local resolver via --resolve, same trick as add-tenant phase 13.
if [[ -n "${BEBOP_DNS_ZONE:-}" && "$DOMAIN" != "${TENANT_ID}.${BEBOP_DNS_ZONE}" ]]; then
    host_ip=$(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    host_ipv6=$(curl -sS --max-time 10 https://api6.ipify.org 2>/dev/null || true)
    if [[ -n "$host_ip" && -n "$host_ipv6" ]]; then
        healthcheck_extra=( --resolve "${DOMAIN}:443:${host_ip},${host_ipv6}" )
        log_info "external mode detected: --resolve ${DOMAIN}:443:${host_ip},${host_ipv6}"
    fi
fi
if ! http_wait_ok "https://${DOMAIN}/" "$HEALTHCHECK_RETRIES" "$HEALTHCHECK_INTERVAL" \
        "${healthcheck_extra[@]+"${healthcheck_extra[@]}"}"; then
    notify_failure \
        "[be-BOP tooling] restore ${TENANT_ID} FAILED (healthcheck)" \
        "Tenant ${TENANT_ID} restore from ${FTP_PATH} completed but the healthcheck timed out.
Investigate: journalctl -u bebop@${TENANT_ID} --since '15 min ago'"
    die "healthcheck failed for https://${DOMAIN}/"
fi

notify_success \
    "[be-BOP tooling] restore ${TENANT_ID} OK" \
    "Tenant ${TENANT_ID} restored from ${FTP_PATH} (pre-backup was $(if [[ "$PRE_BACKUP" == "true" ]]; then echo "taken"; else echo "skipped"; fi))."
log_info "restore OK ✓"

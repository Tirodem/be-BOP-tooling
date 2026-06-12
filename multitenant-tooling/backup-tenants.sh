#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# backup-tenants.sh — produce per-tenant encrypted backups and upload to SFTP.
#
# Live backup (no bebop downtime):
#   - mongodump of the per-tenant DB (consistent via replica-set oplog)
#   - rclone sync of the Garage S3 bucket
#   - phoenixd seed.dat + phoenix.conf (Lightning wallet recovery + HTTP password)
#   - /etc/be-BOP/<tenant>/config.env
#   - metadata.json (tenant info: domain, ports, version, timestamps)
#
# All bundled into a single .zip, encrypted with openssl AES-256-CBC + PBKDF2,
# uploaded to SFTP_REMOTE_PATH/<tenant>/<YYYYMMDDTHHMMSSZ>.zip.enc.
#
# Two encryption modes:
#   default       Encrypts with BACKUP_ENCRYPTION_KEY from secrets.env. The
#                 same VDS (or any VDS sharing the same secrets.env) can
#                 restore non-interactively. Use this for VDS↔VDS migration
#                 and routine ops backups.
#   --for-handoff Generates a fresh random passphrase, prints it once on
#                 stdout at the end of the run (per-tenant). Hand it to the
#                 merchant out-of-band; the merchant decrypts on their own
#                 infra with `openssl enc -d`. The BACKUP_ENCRYPTION_KEY is
#                 NOT used, so the merchant doesn't gain access to anyone
#                 else's backups.

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="backup-tenants"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "backup-tenants: cannot locate lib/ directory" >&2
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
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# === CLI ================================================================
SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
ALL=false
FOR_HANDOFF=false
DRY_RUN=false
TENANT_IDS=()

usage() {
    cat <<EOF
backup-tenants.sh — encrypted per-tenant backup to SFTP.

Usage:
  backup-tenants.sh <tenant_id> [<tenant_id>...] [options]
  backup-tenants.sh --all [options]

Options:
  --all                  back up every tenant whose status=active in the registry
  --for-handoff          per-backup random passphrase (printed once); use when
                         the recipient is the MERCHANT, not the VDS operator.
                         Default mode uses BACKUP_ENCRYPTION_KEY from secrets.env
                         (auto-restorable on any VDS sharing the same secrets).
  --secrets-file <path>  override default ${SECRETS_FILE}
  --dry-run              print actions without executing
  -h, --help

Each backup is a .zip containing:
  - mongo-dump/                  (per-tenant DB dump, mongodump --gzip --archive)
  - bucket/                      (rclone sync of the tenant's Garage bucket)
  - phoenixd/seed.dat            (Lightning wallet seed)
  - phoenixd/phoenix.conf        (includes the phoenixd HTTP password)
  - config.env                   (tenant's be-BOP env file)
  - metadata.json                (tenant identifiers + version + timestamps)

The zip is encrypted with openssl AES-256-CBC + PBKDF2 (100000 iterations)
and uploaded to SFTP_REMOTE_PATH/<tenant_id>/<YYYYMMDDTHHMMSSZ>.zip.enc.

Restore guidance is in the operator output at end-of-run.
EOF
}

while (( $# )); do
    case "$1" in
        --all)            ALL=true; shift ;;
        --for-handoff)    FOR_HANDOFF=true; shift ;;
        --secrets-file)   SECRETS_FILE="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *)  TENANT_IDS+=("$1"); shift ;;
    esac
done

if [[ "$ALL" == "true" && ${#TENANT_IDS[@]} -gt 0 ]]; then
    die "--all is mutually exclusive with explicit tenant ids"
fi
if [[ "$ALL" != "true" && ${#TENANT_IDS[@]} -eq 0 ]]; then
    usage; die "specify at least one tenant_id, or --all"
fi

require_privileges
if [[ ! -f "$SECRETS_FILE" ]]; then
    die "secrets file not found: ${SECRETS_FILE}"
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# SFTP destination must be configured for ANY backup to make sense.
[[ -z "${SFTP_HOST:-}" ]]       && die "SFTP_HOST not set in ${SECRETS_FILE}"
[[ -z "${SFTP_USER:-}" ]]       && die "SFTP_USER not set in ${SECRETS_FILE}"
[[ -z "${SFTP_REMOTE_PATH:-}" ]] && die "SFTP_REMOTE_PATH not set in ${SECRETS_FILE}"
[[ -z "${SFTP_PASSWORD_OR_KEY_PATH:-}" ]] && die "SFTP_PASSWORD_OR_KEY_PATH not set in ${SECRETS_FILE}"

# Default-mode also needs the operator key.
if [[ "$FOR_HANDOFF" != "true" && -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
    die "BACKUP_ENCRYPTION_KEY not set in ${SECRETS_FILE} (or use --for-handoff for a one-shot passphrase)"
fi

registry_init

# Resolve the tenant list.
if [[ "$ALL" == "true" ]]; then
    mapfile -t TENANT_IDS < <(registry_list_by_status active)
fi
if (( ${#TENANT_IDS[@]} == 0 )); then
    log_info "no tenants to back up"
    exit 0
fi

# Each tenant must exist + be active.
for t in "${TENANT_IDS[@]}"; do
    s=$(registry_get_status "$t")
    case "$s" in
        active) ;;
        absent) die "tenant '${t}' not in registry" ;;
        *)      die "tenant '${t}' has status '${s}'; only active tenants can be backed up" ;;
    esac
done

log_info "backup-tenants: ${#TENANT_IDS[@]} tenant(s): ${TENANT_IDS[*]}  (mode: $(if [[ "$FOR_HANDOFF" == "true" ]]; then echo "handoff"; else echo "ops"; fi))"

# === Per-tenant backup ===================================================
# Globals populated by do_backup_tenant for the summary at end.
SUCCEEDED=()
FAILED=()
declare -A HANDOFF_PASSPHRASE   # tenant_id → passphrase (only in --for-handoff)
declare -A HANDOFF_SFTP_PATH    # tenant_id → SFTP relative path

do_backup_tenant() {
    local tenant="$1"
    BEBOP_TOOLING_TENANT_ID="$tenant"
    export BEBOP_TOOLING_TENANT_ID
    log_info "backup: starting"

    # Read tenant fields.
    local domain mongo_port mongo_db garage_bucket bebop_version
    domain=$(registry_get_field "$tenant" domain)
    mongo_port=$(registry_get_field "$tenant" mongo_port)
    mongo_db=$(registry_get_field "$tenant" mongodb_database)
    garage_bucket=$(registry_get_field "$tenant" garage_bucket)
    bebop_version=$(registry_get_field "$tenant" bebop_version)

    local timestamp
    timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
    local workdir
    workdir=$(mktemp -d "/var/tmp/bebop-backup-${tenant}.XXXXXX")
    chmod 0700 "$workdir"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would mongodump / rclone / zip / encrypt / upload"
        return 0
    fi

    # 1. mongodump (replica-set oplog gives a consistent snapshot).
    log_info "backup: mongodump db=${mongo_db} port=${mongo_port}"
    mkdir -p "${workdir}/mongo-dump"
    mongo_dump_db "$mongo_port" "$mongo_db" "${workdir}/mongo-dump" \
        || die "mongodump failed for ${mongo_db}"

    # 2. Garage bucket sync (only when the tenant has a local Garage bucket).
    if [[ -n "$garage_bucket" ]]; then
        log_info "backup: rclone sync garage:${garage_bucket} → bucket/"
        local key_id key_secret
        key_id=$(run_privileged grep -oP '^S3_KEY_ID=\K.*' "/etc/be-BOP/${tenant}/config.env" 2>/dev/null || true)
        key_secret=$(run_privileged grep -oP '^S3_KEY_SECRET=\K.*' "/etc/be-BOP/${tenant}/config.env" 2>/dev/null || true)
        if [[ -z "$key_id" || -z "$key_secret" ]]; then
            log_warn "Garage credentials missing from config.env; bucket sync SKIPPED"
        else
            mkdir -p "${workdir}/bucket"
            RCLONE_CONFIG_GARAGE_TYPE=s3 \
            RCLONE_CONFIG_GARAGE_PROVIDER=Other \
            RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900 \
            RCLONE_CONFIG_GARAGE_REGION=garage \
            RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$key_id" \
            RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$key_secret" \
                rclone --quiet sync "garage:${garage_bucket}" "${workdir}/bucket" \
                || die "rclone Garage sync failed"
        fi
    else
        log_info "backup: tenant has no local Garage bucket (--no-local-s3 at create time); skipping S3 dump"
    fi

    # 3. phoenixd seed + http-password.
    mkdir -p "${workdir}/phoenixd"
    local phoenix_dir="/var/lib/phoenixd/${tenant}/.phoenix"
    if run_privileged test -r "${phoenix_dir}/seed.dat"; then
        run_privileged cat "${phoenix_dir}/seed.dat" > "${workdir}/phoenixd/seed.dat"
        chmod 0600 "${workdir}/phoenixd/seed.dat"
    else
        log_warn "phoenixd seed.dat not readable; skipping"
    fi
    if run_privileged test -r "${phoenix_dir}/phoenix.conf"; then
        run_privileged cat "${phoenix_dir}/phoenix.conf" > "${workdir}/phoenixd/phoenix.conf"
        chmod 0600 "${workdir}/phoenixd/phoenix.conf"
    else
        log_warn "phoenix.conf not readable; skipping"
    fi

    # 4. tenant config.env.
    if run_privileged test -r "/etc/be-BOP/${tenant}/config.env"; then
        run_privileged cat "/etc/be-BOP/${tenant}/config.env" > "${workdir}/config.env"
        chmod 0600 "${workdir}/config.env"
    else
        log_warn "config.env not readable; skipping"
    fi

    # 5. metadata.json — operational identifiers, no secrets.
    cat > "${workdir}/metadata.json" <<EOF
{
  "tenant_id":        "${tenant}",
  "domain":           "${domain}",
  "mongo_port":       ${mongo_port},
  "mongodb_database": "${mongo_db}",
  "garage_bucket":    "${garage_bucket}",
  "bebop_version":    "${bebop_version}",
  "backed_up_at":     "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "backup_format":    "1",
  "encryption":       "openssl aes-256-cbc + pbkdf2 (100000 iters), $(if [[ "$FOR_HANDOFF" == "true" ]]; then echo "random per-backup passphrase"; else echo "BACKUP_ENCRYPTION_KEY"; fi)"
}
EOF

    # 6. zip the bundle.
    local zip_file="${workdir}.zip"
    ( cd "$workdir" && zip -q -r "$zip_file" . ) \
        || die "zip failed"

    # 7. encrypt.
    local enc_file="${workdir}.zip.enc"
    local passphrase
    if [[ "$FOR_HANDOFF" == "true" ]]; then
        passphrase=$(openssl rand -base64 48 | tr -d '\n' | head -c 64)
        HANDOFF_PASSPHRASE["$tenant"]="$passphrase"
    else
        passphrase="$BACKUP_ENCRYPTION_KEY"
    fi
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -pass "pass:${passphrase}" \
        -in "$zip_file" -out "$enc_file" \
        || die "openssl encrypt failed"
    rm -f "$zip_file"

    # 8. upload to SFTP.
    local sftp_subpath="${tenant}/${timestamp}.zip.enc"
    log_info "backup: uploading to sftp://${SFTP_HOST}${SFTP_REMOTE_PATH}/${sftp_subpath}"
    local rc_args=(
        --sftp-host "$SFTP_HOST"
        --sftp-port "${SFTP_PORT:-22}"
        --sftp-user "$SFTP_USER"
    )
    if [[ "${SFTP_PASSWORD_OR_KEY_PATH}" == /* ]]; then
        rc_args+=(--sftp-key-file "$SFTP_PASSWORD_OR_KEY_PATH")
    else
        local obs
        obs=$(rclone obscure "$SFTP_PASSWORD_OR_KEY_PATH")
        rc_args+=(--sftp-pass "$obs")
    fi
    RCLONE_CONFIG_BACKUP_TYPE=sftp \
    RCLONE_CONFIG_BACKUP_HOST="$SFTP_HOST" \
    RCLONE_CONFIG_BACKUP_PORT="${SFTP_PORT:-22}" \
    RCLONE_CONFIG_BACKUP_USER="$SFTP_USER" \
        rclone "${rc_args[@]}" copyto "$enc_file" "backup:${SFTP_REMOTE_PATH}/${sftp_subpath}" \
        || die "SFTP upload failed"

    HANDOFF_SFTP_PATH["$tenant"]="${SFTP_REMOTE_PATH}/${sftp_subpath}"
    log_info "backup: uploaded ${SFTP_REMOTE_PATH}/${sftp_subpath} ($(stat -c %s "$enc_file") bytes)"
}

# Iterate tenants; continue on failure (a broken tenant doesn't abort the others).
for t in "${TENANT_IDS[@]}"; do
    if ( do_backup_tenant "$t" ); then
        SUCCEEDED+=("$t")
    else
        FAILED+=("$t")
        log_error "backup-tenants: ${t} FAILED — continuing"
    fi
done

# Clear tenant tag for the global summary.
BEBOP_TOOLING_TENANT_ID=""
export BEBOP_TOOLING_TENANT_ID

# === Summary + hand-off sheet ============================================
echo ""
echo "=========================================================================="
echo "  backup-tenants summary"
echo "=========================================================================="
echo "  Selected:  ${#TENANT_IDS[@]}"
echo "  Succeeded: ${#SUCCEEDED[@]}  ${SUCCEEDED[*]:-}"
echo "  Failed:    ${#FAILED[@]}  ${FAILED[*]:-}"
echo "=========================================================================="

if [[ "$FOR_HANDOFF" == "true" && ${#SUCCEEDED[@]} -gt 0 ]]; then
    echo ""
    echo "===== HAND-OFF SHEETS (sensitive — transmit OOB, do not log) ====="
    for t in "${SUCCEEDED[@]}"; do
        cat <<EOF

  Tenant:        ${t}
  SFTP path:     ${HANDOFF_SFTP_PATH[$t]}
  Passphrase:    ${HANDOFF_PASSPHRASE[$t]}
  Decrypt with:
    openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \\
        -pass pass:'${HANDOFF_PASSPHRASE[$t]}' \\
        -in <downloaded>.zip.enc \\
        -out tenant-${t}.zip
    unzip tenant-${t}.zip
EOF
    done
    echo ""
    echo "Reminder: --for-handoff uses a ONE-TIME passphrase per backup. There is"
    echo "no recovery if you lose it — transmit it to the merchant securely now."
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    notify_failure \
        "[be-BOP tooling] backup-tenants had ${#FAILED[@]} failure(s)" \
        "Failed tenants: ${FAILED[*]}
Succeeded:      ${SUCCEEDED[*]:-(none)}"
    exit 1
fi
notify_success \
    "[be-BOP tooling] backup-tenants OK (${#SUCCEEDED[@]} tenants)" \
    "Tenants: ${SUCCEEDED[*]}"

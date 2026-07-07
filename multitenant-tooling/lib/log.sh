# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# log.sh — structured logging for be-BOP multi-tenant tooling.
# Source this file. Do NOT execute it directly, and do NOT set -e/-u inside
# (that is the calling script's responsibility).
#
# Caller-overridable environment variables:
#   BEBOP_TOOLING_SYSLOG_IDENT  — syslog tag (default: bebop-tooling)
#   BEBOP_TOOLING_TENANT_ID     — adds [tenant=<id>] to every log line if set
#   VERBOSE                     — set "true" to enable log_debug output
#
# Public API:
#   log_info|log_warn|log_error|log_debug <message...>
#   die <message...>
#   mask_secrets    — filter pipeline that redacts known secret-shaped values

[[ -n "${_BEBOP_LOG_SOURCED:-}" ]] && return 0
readonly _BEBOP_LOG_SOURCED=1

: "${BEBOP_TOOLING_SYSLOG_IDENT:=bebop-tooling}"
: "${BEBOP_TOOLING_TENANT_ID:=}"
: "${VERBOSE:=false}"

# Session id is propagated to children so a single multi-process run shares one
# correlation id in the journal.
if [[ -z "${BEBOP_TOOLING_SESSION_ID:-}" ]]; then
    BEBOP_TOOLING_SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    export BEBOP_TOOLING_SESSION_ID
fi

_log_emit() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local prefix="[${BEBOP_TOOLING_SESSION_ID}] [${timestamp}] [${level}]"
    [[ -n "$BEBOP_TOOLING_TENANT_ID" ]] && prefix+=" [tenant=${BEBOP_TOOLING_TENANT_ID}]"
    local line="${prefix} $*"
    # Redact known secret-shaped values before ANY sink writes. Applies to
    # stderr, systemd-cat, and the err-log used in notify_failure bodies.
    local masked
    masked=$(printf '%s' "$line" | mask_secrets) || masked="$line"
    line="$masked"
    printf '%s\n' "$line" >&2
    if command -v systemd-cat >/dev/null 2>&1; then
        local prio
        case "$level" in
            ERROR) prio=err ;;
            WARN)  prio=warning ;;
            INFO)  prio=info ;;
            DEBUG) prio=debug ;;
            *)     prio=notice ;;
        esac
        printf '%s\n' "$line" | systemd-cat -t "$BEBOP_TOOLING_SYSLOG_IDENT" -p "$prio" 2>/dev/null || true
    fi
    # Persist ERROR / WARN lines to a per-session file so notify_failure can
    # include the actual cause in the body — instead of operators having to
    # ssh in and grep journalctl to figure out what went wrong.
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        local err_log="${TMPDIR:-/tmp}/bebop-tooling.${BEBOP_TOOLING_SESSION_ID}.err"
        if [[ ! -e "$err_log" ]]; then
            (umask 077 && : >"$err_log") 2>/dev/null || true
        fi
        printf '%s\n' "$line" >>"$err_log" 2>/dev/null || true
    fi
}

log_info()  { _log_emit INFO  "$@"; }
log_warn()  { _log_emit WARN  "$@"; }
log_error() { _log_emit ERROR "$@"; }
log_debug() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        _log_emit DEBUG "$@"
    fi
}

die() {
    log_error "$@"
    exit 1
}

# defer_die <message>
# Config-tolerant die: in --defer-secrets install mode (DEFER_SECRETS=true
# in the calling script's env), warn and return 1 so the caller can skip
# the step. In normal mode, dies loudly with the usual exit 1.
# Use this for ANY envvar / secrets / config-completeness check — never
# raw die on missing config, otherwise a fresh install (or a --clean +
# re-run) crashes instead of gracefully proceeding to the "fill your
# secrets.env and re-run" state. Real system failures (arch unsupported,
# corepack missing, sha256 mismatch, service didn't come up) still use
# die directly.
defer_die() {
    if [[ "${DEFER_SECRETS:-false}" == "true" ]]; then
        log_warn "$@"
        return 1
    fi
    die "$@"
}

# Filter stdin → stdout, redacting common secret patterns.
# Use it when piping subprocess output that may contain credentials.
mask_secrets() {
    sed -E \
        -e 's/(OVH_[A-Z_]*KEY|OVH_[A-Z_]*SECRET|INFOMANIAK_API_TOKEN|SMTP_PASSWORD|ZULIP_[A-Z_]*KEY|UPTIME_KUMA_API_KEY|SFTP_PASSWORD|GARAGE_KEY_SECRET|PHOENIXD_HTTP_PASSWORD|MONGODB_URL|BACKUP_ENCRYPTION_KEY)=([^[:space:]]+)/\1=***REDACTED***/g' \
        -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+/\1***REDACTED***/g' \
        -e 's/(Authorization:[[:space:]]*Basic[[:space:]]+)[A-Za-z0-9+/=]+/\1***REDACTED***/g' \
        -e 's/(X-Ovh-Application:[[:space:]]+)[A-Za-z0-9]+/\1***REDACTED***/g' \
        -e 's/(X-Ovh-Consumer:[[:space:]]+)[A-Za-z0-9]+/\1***REDACTED***/g' \
        -e 's/(X-Ovh-Signature:[[:space:]]+)\$1\$[A-Za-z0-9]+/\1***REDACTED***/g' \
        -e 's|(mongodb(\+srv)?://)[^:@[:space:]]+:[^@[:space:]]+@|\1***REDACTED***@|g'
}

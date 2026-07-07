# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# healthcheck.sh — HTTP/TCP polling helpers.
# Source AFTER lib/log.sh.

[[ -n "${_BEBOP_HEALTHCHECK_SOURCED:-}" ]] && return 0
readonly _BEBOP_HEALTHCHECK_SOURCED=1

# http_wait_ok <url> [retries=30] [interval_sec=2] [extra_curl_arg...]
# Polls until the URL returns HTTP 2xx/3xx. Returns 0 on success, 1 on timeout.
# Connect+request capped at 5s per attempt.
#
# Extra args after the interval are appended to the curl command — used by
# add-tenant.sh phase_healthcheck to inject `--resolve <fqdn>:443:<ip>[,<ipv6>]`
# in external-domain mode, bypassing the VDS's local resolver (which may
# still have a negative cache from before the operator set their DNS).
http_wait_ok() {
    local url="$1" retries="${2:-30}" interval="${3:-2}"
    local extra_args=()
    if (( $# > 3 )); then
        shift 3
        extra_args=("$@")
    fi
    local i status
    for (( i=1; i<=retries; i++ )); do
        status=$(curl "${extra_args[@]+"${extra_args[@]}"}" \
            -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null \
            || echo "000")
        if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
            log_debug "http_wait_ok: ${url} → ${status} (try ${i}/${retries})"
            return 0
        fi
        if (( i < retries )); then
            log_debug "http_wait_ok: ${url} → ${status} (try ${i}/${retries}); waiting ${interval}s"
            sleep "$interval"
        fi
    done
    log_error "http_wait_ok: ${url} did not return 2xx/3xx within $((retries * interval))s"
    return 1
}

# tcp_port_open <host> <port> [timeout_sec=5]
# Returns 0 if a TCP connect succeeds, else 1.
tcp_port_open() {
    local host="$1" port="$2" timeout="${3:-5}"
    if command -v ncat >/dev/null 2>&1; then
        ncat -z -w "$timeout" "$host" "$port" 2>/dev/null
    elif command -v nc >/dev/null 2>&1; then
        nc -z -w "$timeout" "$host" "$port" 2>/dev/null
    else
        # Fallback using bash's /dev/tcp pseudo-device.
        timeout "$timeout" bash -c "exec 9<>/dev/tcp/${host}/${port}" 2>/dev/null
    fi
}

# tcp_wait_open <host> <port> [retries=20] [interval_sec=1]
tcp_wait_open() {
    local host="$1" port="$2" retries="${3:-20}" interval="${4:-1}"
    local i
    for (( i=1; i<=retries; i++ )); do
        if tcp_port_open "$host" "$port" 2; then
            log_debug "tcp_wait_open: ${host}:${port} ready (try ${i}/${retries})"
            return 0
        fi
        (( i < retries )) && sleep "$interval"
    done
    log_error "tcp_wait_open: ${host}:${port} did not open within $((retries * interval))s"
    return 1
}

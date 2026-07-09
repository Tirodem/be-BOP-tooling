#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# list-tenants.sh — print the be-BOP tenants registry
# (/var/lib/be-BOP/tenants.tsv) in a few useful formats.
#
# Usage:
#   list-tenants.sh                       # all tenants, table format
#   list-tenants.sh --status active       # filter by status
#   list-tenants.sh --format json         # newline-delimited JSON
#   list-tenants.sh --format tsv          # raw TSV passthrough
#   list-tenants.sh --with-systemd        # add a systemd state column
#
# Reads the registry directly (no API calls, no mutation). Requires
# read access to the registry file (run via sudo).

set -eEuo pipefail

readonly SCRIPT_NAME="list-tenants"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "list-tenants: cannot locate lib/ directory" >&2
    exit 1
fi

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

STATUS_FILTER=""
FORMAT="text"
WITH_SYSTEMD=false

usage() {
    cat <<EOF
list-tenants.sh — print the be-BOP tenants registry.

Usage:
  list-tenants.sh [options]

Options:
  --status <s>      Filter to one status (active|soft-deleted|archived).
  --format <f>      Output format: text (default) | json | tsv.
                      text → human-readable column-aligned table
                      json → newline-delimited JSON, one object per tenant
                      tsv  → raw registry passthrough (with header)
  --with-systemd    Add a 'systemd' column with the live state of
                    bebop@<id>, phoenixd@<id>, mongod@<id> (text format only).
  -h, --help

Examples:
  sudo list-tenants.sh
  sudo list-tenants.sh --status active --with-systemd
  sudo list-tenants.sh --format json | jq '.tenant_id'
EOF
}

while (( $# )); do
    case "$1" in
        --status)        STATUS_FILTER="$2"; shift 2 ;;
        --format)        FORMAT="$2"; shift 2 ;;
        --with-systemd)  WITH_SYSTEMD=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

case "$FORMAT" in
    text|json|tsv) ;;
    *) die "invalid --format '${FORMAT}' (expected text|json|tsv)" ;;
esac

if [[ -n "$STATUS_FILTER" ]]; then
    case "$STATUS_FILTER" in
        active|soft-deleted|archived) ;;
        *) die "invalid --status '${STATUS_FILTER}' (expected active|soft-deleted|archived)" ;;
    esac
fi

require_privileges

if ! run_privileged test -f "$REGISTRY_PATH"; then
    log_warn "registry ${REGISTRY_PATH} does not exist — has host-bootstrap.sh been run?"
    exit 0
fi

# read_tsv: emit the (optionally filtered) registry on stdout AFTER a
# display-only reshape. Registry file itself is untouched. Transformations:
#   - domain            → domain:bebop_port      (e.g. "shop.example.com:3005")
#   - ln_port           = ex-phoenixd_port       (renamed for compactness)
#   - mongodb_database  → mongodb_database:mongo_port  (e.g. "bebop_x:27030")
#   - garage_key        DROPPED (long, rarely needed for triage)
#   - bebop_port / phoenixd_port / mongo_port DROPPED as standalone columns
#   - expires_at        appended from test-tenant-expiry.tsv (empty if untracked)
# Column headers in emitted output reflect the new schema.
read_tsv() {
    local expiry_path="${TEST_TENANT_EXPIRY_PATH:-/var/lib/be-BOP/test-tenant-expiry.tsv}"
    local expiry_content=""
    if run_privileged test -f "$expiry_path"; then
        expiry_content=$(run_privileged cat "$expiry_path")
    fi
    local status_filter="${STATUS_FILTER:-}"
    # Registry columns: 1=tenant_id 2=domain 3=bebop_port 4=phoenixd_port
    # 5=mongo_port 6=mongodb_database 7=garage_bucket 8=garage_key
    # 9=bebop_version 10=created_at 11=status 12=external.
    run_privileged cat "$REGISTRY_PATH" | awk -F'\t' -v OFS='\t' \
        -v sfilter="$status_filter" -v expiry_data="$expiry_content" '
        BEGIN {
            if (expiry_data != "") {
                n = split(expiry_data, lines, "\n")
                for (i = 2; i <= n; i++) {
                    if (lines[i] == "") continue
                    split(lines[i], f, "\t")
                    if (f[1] != "") expiry[f[1]] = f[2]
                }
            }
        }
        NR == 1 {
            print "tenant_id", "domain", "ln_port", "mongodb_database", \
                  "garage_bucket", "bebop_version", "created_at", "status", \
                  "external", "expires_at"
            next
        }
        {
            if (sfilter != "" && $11 != sfilter) next
            expires = ($1 in expiry) ? expiry[$1] : ""
            print $1, $2 ":" $3, $4, $6 ":" $5, $7, $9, $10, $11, $12, expires
        }
    '
}

systemd_state_for() {
    local t="$1" b p m
    b=$(run_privileged systemctl is-active "bebop@${t}.service" 2>/dev/null || echo inactive)
    p=$(run_privileged systemctl is-active "phoenixd@${t}.service" 2>/dev/null || echo inactive)
    m=$(run_privileged systemctl is-active "mongod@${t}.service" 2>/dev/null || echo inactive)
    printf 'bebop=%s,phoenixd=%s,mongod=%s' "$b" "$p" "$m"
}

emit_text() {
    local tsv
    tsv=$(read_tsv)
    if [[ "$WITH_SYSTEMD" != "true" ]]; then
        printf '%s\n' "$tsv" | column -t -s$'\t'
        return 0
    fi
    {
        local first=true line
        while IFS= read -r line; do
            if [[ "$first" == "true" ]]; then
                printf '%s\tsystemd\n' "$line"
                first=false
            else
                local tenant
                tenant=$(printf '%s' "$line" | cut -f1)
                [[ -z "$tenant" ]] && continue
                printf '%s\t%s\n' "$line" "$(systemd_state_for "$tenant")"
            fi
        done <<<"$tsv"
    } | column -t -s$'\t'
}

emit_json() {
    if ! command -v jq >/dev/null 2>&1; then
        die "jq is required for --format json (apt install jq)"
    fi
    read_tsv | jq -Rs -c '
        split("\n") | map(select(length > 0)) | map(split("\t"))
        | (.[0]) as $hdr | .[1:]
        | map(. as $row
            | reduce range(0; $hdr|length) as $i ({}; .[$hdr[$i]] = ($row[$i] // "")))
        | .[]
    '
}

emit_tsv() {
    read_tsv
}

case "$FORMAT" in
    text) emit_text ;;
    tsv)  emit_tsv ;;
    json) emit_json ;;
esac

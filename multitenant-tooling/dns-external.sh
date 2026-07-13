#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# dns-external.sh — print the DNS records the client MUST set on their
# external domain before running `add-tenant.sh --external-domain <fqdn>`.
#
# add-tenant.sh in external-domain mode issues the cert via HTTP-01
# webroot, which requires the target domain to resolve to this VDS
# BEFORE we call certbot. We hand the operator a copy-pasteable table
# to forward to the client so this DNS step is out of the way ahead of
# provisioning.
#
# IPv6 is REQUIRED: add-tenant.sh dies without a public IPv6 on the VDS
# (see check around line 362). We surface the same error here so a
# missing IPv6 is caught during onboarding prep, not at provisioning
# time.

set -eEuo pipefail

readonly SCRIPT_NAME="dns-external"

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

: "${SECRETS_FILE:=/etc/be-BOP-tooling/secrets.env}"

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

TARGET=""
FORMAT="table"

usage() {
    cat <<EOF
${SCRIPT_NAME}.sh — print the DNS records the client must set on their
external domain BEFORE running add-tenant.sh --external-domain <fqdn>.

Usage:
  ${SCRIPT_NAME}.sh --target <fqdn> [--format table|markdown|tsv]

Options:
  --target <fqdn>     the client's external domain (e.g. shop.client.com)
  --format <f>        table (default) | markdown | tsv
                        table    — column-aligned, ideal for terminal
                        markdown — pipe table, ideal for chat / email
                        tsv      — tab-separated, ideal for spreadsheets
  -h, --help
EOF
}

while (( $# )); do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --format) FORMAT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

[[ -z "$TARGET" ]] && { usage; die "--target is required"; }
if [[ ! "$TARGET" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    die "invalid --target '${TARGET}' (expected an FQDN)"
fi
case "$FORMAT" in
    table|markdown|tsv) ;;
    *) die "invalid --format '${FORMAT}' (expected table|markdown|tsv)" ;;
esac

# Prefer overrides from secrets.env (BEBOP_HOST_IP / BEBOP_HOST_IPV6) so
# multi-homed VDS or NAT setups can pin the addresses instead of relying
# on ipify. secrets.env is 0600; without sudo the source silently no-ops
# and we fall back to ipify — which is fine, this script is read-only.
if [[ -r "$SECRETS_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
    set +a
fi

IP4="${BEBOP_HOST_IP:-}"
if [[ -z "$IP4" ]]; then
    IP4=$(curl -sS -4 --max-time 10 https://api.ipify.org 2>/dev/null || true)
fi
[[ -z "$IP4" ]] && die "could not determine the VDS IPv4 (set BEBOP_HOST_IP in secrets.env or check network)"

IP6="${BEBOP_HOST_IPV6:-}"
if [[ -z "$IP6" ]]; then
    IP6=$(curl -sS -6 --max-time 10 https://api64.ipify.org 2>/dev/null || true)
fi
[[ -z "$IP6" ]] && die "could not determine the VDS IPv6 — external-domain tenants require IPv6 on the VDS. Set BEBOP_HOST_IPV6 in secrets.env or enable IPv6 on the network stack."

case "$FORMAT" in
    table)
        { printf 'type\tname\tvalue\n'
          printf 'A\t%s\t%s\n'    "$TARGET" "$IP4"
          printf 'AAAA\t%s\t%s\n' "$TARGET" "$IP6"
        } | column -t -s$'\t'
        ;;
    markdown)
        printf '| type | name | value |\n'
        printf '|------|------|-------|\n'
        printf '| A    | %s | %s |\n' "$TARGET" "$IP4"
        printf '| AAAA | %s | %s |\n' "$TARGET" "$IP6"
        ;;
    tsv)
        printf 'type\tname\tvalue\n'
        printf 'A\t%s\t%s\n'    "$TARGET" "$IP4"
        printf 'AAAA\t%s\t%s\n' "$TARGET" "$IP6"
        ;;
esac

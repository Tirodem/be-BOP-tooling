# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# dns_provider.sh — provider-agnostic DNS mutation façade.
#
# Callers source this file (not the concrete backend) and use:
#   dns_provider_is_configured
#   dns_provider_ping
#   dns_provider_dns_record_find    <subdomain> <type>
#   dns_provider_dns_record_create  <subdomain> <type> <target> [ttl]
#   dns_provider_dns_record_delete  <record_id>
#   dns_provider_dns_zone_refresh
#
# Backend is picked at FIRST CALL time via the DNS_PROVIDER env var
# (loaded from /etc/be-BOP-tooling/secrets.env). Sourcing this file
# does NOT read DNS_PROVIDER — the caller scripts source their libs
# at the top of the file, but secrets.env is loaded later, so an
# eager source-time dispatch would always pick the default. The
# wrappers below defer the backend load to the first call, at which
# point secrets.env has been read.
#
#   DNS_PROVIDER=ovh         → lib/ovh.sh
#   DNS_PROVIDER=infomaniak  → lib/infomaniak.sh
# Empty DNS_PROVIDER dies loudly — no silent fallback.
#
# Adding a new provider = drop lib/<name>.sh implementing the same
# function names, then extend the case in _dns_provider_load_backend.
#
# Source AFTER lib/log.sh.

[[ -n "${_BEBOP_DNS_PROVIDER_SOURCED:-}" ]] && return 0
readonly _BEBOP_DNS_PROVIDER_SOURCED=1

: "${BEBOP_TOOLING_LIB_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# One-shot backend loader. Idempotent — subsequent calls no-op via the
# _BEBOP_DNS_PROVIDER_BACKEND_SOURCED sentinel. Sourcing the backend
# REDEFINES every dns_provider_* function below, so the wrapper is
# replaced by the real implementation from that point on.
_dns_provider_load_backend() {
    [[ -n "${_BEBOP_DNS_PROVIDER_BACKEND_SOURCED:-}" ]] && return 0
    case "${DNS_PROVIDER:-}" in
        "")
            die "dns_provider: DNS_PROVIDER is empty. Set it explicitly to 'ovh' or 'infomaniak' in ${SECRETS_FILE:-/etc/be-BOP-tooling/secrets.env}."
            ;;
        ovh)
            # shellcheck source=ovh.sh
            source "${BEBOP_TOOLING_LIB_DIR}/ovh.sh"
            ;;
        infomaniak)
            # shellcheck source=infomaniak.sh
            source "${BEBOP_TOOLING_LIB_DIR}/infomaniak.sh"
            ;;
        *)
            die "dns_provider: unknown DNS_PROVIDER='${DNS_PROVIDER}' (want: ovh|infomaniak)"
            ;;
    esac
    _BEBOP_DNS_PROVIDER_BACKEND_SOURCED=1
}

# Wrappers: source the backend on first invocation, then dispatch to
# the newly-defined real function. bash resolves function names at
# call-time, so `dns_provider_ping "$@"` on the last line hits the
# real impl (which the source just installed), not this stub — no
# infinite recursion.
dns_provider_is_configured()      { _dns_provider_load_backend; dns_provider_is_configured "$@"; }
dns_provider_ping()               { _dns_provider_load_backend; dns_provider_ping "$@"; }
dns_provider_dns_record_find()    { _dns_provider_load_backend; dns_provider_dns_record_find "$@"; }
dns_provider_dns_record_create()  { _dns_provider_load_backend; dns_provider_dns_record_create "$@"; }
dns_provider_dns_record_delete()  { _dns_provider_load_backend; dns_provider_dns_record_delete "$@"; }
dns_provider_dns_zone_refresh()   { _dns_provider_load_backend; dns_provider_dns_zone_refresh "$@"; }

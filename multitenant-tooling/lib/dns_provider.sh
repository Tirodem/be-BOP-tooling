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
            # Not configured — return non-zero without dying.
            # Global install logic: an empty/broken env var must NEVER
            # abort an install action. Callers (dns_provider_is_configured
            # in --defer-secrets, tests, etc.) propagate the false back to
            # their context and skip the DNS-dependent work. The operator
            # gets a warn from host-bootstrap.sh's secrets-check step and
            # is expected to fill DNS_PROVIDER before re-running.
            return 1
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
#
# CANONICAL PATTERN for any future <thing>_provider.sh (sms, mail,
# payment, storage, ...): each wrapper is
#     wrapper() { _<thing>_load_backend || return 1; wrapper "$@"; }
# The `|| return 1` is LOAD-BEARING: if the load fails (empty
# <THING>_PROVIDER envvar → we return 1 to let the caller skip
# gracefully), the wrapper MUST propagate that instead of falling
# through. Otherwise the recursive call goes right back to itself
# (backend never sourced → wrapper is still the current definition)
# and you get a bash stack overflow → segfault on the operator's
# console. Ask 2026-07-07's install debugging how we found out.
dns_provider_is_configured()      { _dns_provider_load_backend || return 1; dns_provider_is_configured "$@"; }
dns_provider_ping()               { _dns_provider_load_backend || return 1; dns_provider_ping "$@"; }
dns_provider_dns_record_find()    { _dns_provider_load_backend || return 1; dns_provider_dns_record_find "$@"; }
dns_provider_dns_record_create()  { _dns_provider_load_backend || return 1; dns_provider_dns_record_create "$@"; }
dns_provider_dns_record_delete()  { _dns_provider_load_backend || return 1; dns_provider_dns_record_delete "$@"; }
dns_provider_dns_zone_refresh()   { _dns_provider_load_backend || return 1; dns_provider_dns_zone_refresh "$@"; }

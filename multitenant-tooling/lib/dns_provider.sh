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
# Backend is picked at source time via the DNS_PROVIDER env var
# (loaded from /etc/be-BOP-tooling/secrets.env):
#   DNS_PROVIDER=ovh         → lib/ovh.sh
#   DNS_PROVIDER=infomaniak  → lib/infomaniak.sh
#
# Adding a new provider = drop lib/<name>.sh implementing the same
# function names, then extend the case below.
#
# Source AFTER lib/log.sh.

[[ -n "${_BEBOP_DNS_PROVIDER_SOURCED:-}" ]] && return 0
readonly _BEBOP_DNS_PROVIDER_SOURCED=1

: "${BEBOP_TOOLING_LIB_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${DNS_PROVIDER:=ovh}"

case "$DNS_PROVIDER" in
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

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# infomaniak.sh — Infomaniak implementation of the dns_provider_* contract.
#
# Selected at runtime via DNS_PROVIDER=infomaniak (see lib/dns_provider.sh).
#
# Public contract (matches lib/ovh.sh):
#   dns_provider_ping
#   dns_provider_is_configured
#   dns_provider_dns_record_find    <subdomain> <type>
#   dns_provider_dns_record_create  <subdomain> <type> <target> [ttl]
#   dns_provider_dns_record_delete  <record_id>
#   dns_provider_dns_zone_refresh
#
# Required env (typically loaded from /etc/be-BOP-tooling/secrets.env):
#   INFOMANIAK_API_TOKEN     — Personal Access Token (product = Domain / DNS)
#   BEBOP_DNS_ZONE           — provider-agnostic zone name (e.g. be-bop.dev)
#
# Optional:
#   INFOMANIAK_API_BASE_URL  default: https://api.infomaniak.com/1
#
# STATUS: stub — bodies wired in phase 2 once the operator provides the
# API token + zone. Any dns_provider_* call in this backend dies loudly so
# a mis-configured VDS (DNS_PROVIDER=infomaniak without creds) surfaces
# immediately instead of silently no-op'ing DNS mutations.
#
# Source AFTER lib/log.sh. Requires `jq` and `curl`.

[[ -n "${_BEBOP_INFOMANIAK_SOURCED:-}" ]] && return 0
readonly _BEBOP_INFOMANIAK_SOURCED=1

: "${INFOMANIAK_API_BASE_URL:=https://api.infomaniak.com/1}"

_infomaniak_not_implemented() {
    die "dns_provider(infomaniak): '$1' not implemented yet — waiting for API token + zone details from operator. Set DNS_PROVIDER=ovh in secrets.env if you still deploy on the OVH-backed zone."
}

dns_provider_is_configured() {
    [[ -n "${INFOMANIAK_API_TOKEN:-}" && -n "${BEBOP_DNS_ZONE:-}" ]]
}

dns_provider_ping() {
    _infomaniak_not_implemented "dns_provider_ping"
}

dns_provider_dns_record_find() {
    _infomaniak_not_implemented "dns_provider_dns_record_find"
}

dns_provider_dns_record_create() {
    _infomaniak_not_implemented "dns_provider_dns_record_create"
}

dns_provider_dns_record_delete() {
    _infomaniak_not_implemented "dns_provider_dns_record_delete"
}

dns_provider_dns_zone_refresh() {
    _infomaniak_not_implemented "dns_provider_dns_zone_refresh"
}

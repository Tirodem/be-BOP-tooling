# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# dns.sh — DNS pre-flight checks for tenant onboarding.
#
# Used by add-tenant.sh --external-domain to confirm the operator has
# correctly configured the external FQDN's A and AAAA records BEFORE the
# tooling starts mutating state (issuing certs, writing vhosts, etc.).
#
# Source AFTER lib/log.sh.
# Requires: dig (apt: dnsutils).

[[ -n "${_BEBOP_DNS_SOURCED:-}" ]] && return 0
readonly _BEBOP_DNS_SOURCED=1

# dns_resolve_a <fqdn>  → prints the first A record (IPv4) or empty.
dns_resolve_a() {
    dig +short +time=5 +tries=2 A "$1" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1
}

# dns_resolve_aaaa <fqdn>  → prints the first AAAA record (IPv6) or empty.
dns_resolve_aaaa() {
    dig +short +time=5 +tries=2 AAAA "$1" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | head -1
}

# dns_check_external_fqdn <fqdn> <expected_ipv4> <expected_ipv6>
# Verifies the FQDN has BOTH A AND AAAA records and they match the expected
# IPs of THIS VDS. Dies with an actionable message (current state + the
# exact config to set on the operator's DNS provider) on any mismatch.
#
# Per B1 design: external-domain mode is "all or nothing" — both records
# must be present AND correct. No --force bypass; the operator must fix
# their DNS first.
dns_check_external_fqdn() {
    local fqdn="$1" want_ipv4="$2" want_ipv6="$3"
    local got_a got_aaaa
    got_a=$(dns_resolve_a "$fqdn")
    got_aaaa=$(dns_resolve_aaaa "$fqdn")

    if [[ "$got_a" == "$want_ipv4" && "$got_aaaa" == "$want_ipv6" ]]; then
        log_debug "DNS pre-flight OK for ${fqdn}: A=${got_a}, AAAA=${got_aaaa}"
        return 0
    fi

    # Multi-line die — the calling die() will log_error it; the per-session
    # err-log capture (lib/log.sh) means this message will also appear in the
    # Zulip + SMTP failure body via notify_failure auto-tail.
    die "$(cat <<EOF
External domain pre-flight failed for ${fqdn}:
  Current A:    ${got_a:-(none)}    (expected: ${want_ipv4})
  Current AAAA: ${got_aaaa:-(none)}    (expected: ${want_ipv6})

To fix, configure these records on your DNS provider:
  A     ${fqdn}  ->  ${want_ipv4}
  AAAA  ${fqdn}  ->  ${want_ipv6}

Both records (A AND AAAA) are required for external-domain mode.
EOF
)"
}

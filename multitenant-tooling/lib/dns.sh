# shellcheck shell=bash
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

# _dns_authoritative_ns <fqdn>
# Walks up the domain labels until an NS RRset is found, returns the first
# NS hostname (no trailing dot) on stdout. Empty if none discoverable.
#
# Example for "bebop.alice.com":
#   dig NS bebop.alice.com   → typically empty (no delegation at sub level)
#   dig NS alice.com         → returns the zone's NS → success
#
# NS lookups still go through the system resolver, but NS records are
# stable (change months/years apart), so cache staleness is a non-issue
# for them — unlike the A / AAAA records we're actually trying to read,
# which the operator may have just changed.
_dns_authoritative_ns() {
    local fqdn="$1" ns
    while [[ "$fqdn" == *.* ]]; do
        ns=$(dig +short +time=3 +tries=1 NS "$fqdn" 2>/dev/null | head -1 | sed 's/\.$//')
        if [[ -n "$ns" ]]; then
            printf '%s\n' "$ns"
            return 0
        fi
        fqdn="${fqdn#*.}"  # drop the leftmost label
    done
}

# dns_resolve_a <fqdn>  → prints the first A record (IPv4) or empty.
# Queries the authoritative NS directly (via @<ns>) to bypass any
# negative-response caching at the local / ISP resolver — important when
# the operator has JUST set the record and the negative cache TTL hasn't
# expired yet.
#
# The `|| true` suffix is load-bearing: "no record found" is grep exit 1,
# which with set -e + pipefail in callers would propagate and fire the ERR
# trap inside the calling $() subshell — and bash's errtrace inheritance
# means the trap fires AGAIN in the parent when the assignment captures
# the subshell's non-zero exit. "No record" is data, not an error.
dns_resolve_a() {
    local fqdn="$1" ns
    ns=$(_dns_authoritative_ns "$fqdn")
    if [[ -n "$ns" ]]; then
        log_debug "dns: querying authoritative NS ${ns} for A ${fqdn}"
        dig +short +time=5 +tries=2 @"$ns" A "$fqdn" 2>/dev/null \
            | grep -E '^[0-9]+(\.[0-9]+){3}$' \
            | head -1 || true
    else
        log_debug "dns: no authoritative NS found for ${fqdn}; falling back to system resolver"
        dig +short +time=5 +tries=2 A "$fqdn" 2>/dev/null \
            | grep -E '^[0-9]+(\.[0-9]+){3}$' \
            | head -1 || true
    fi
}

# dns_resolve_aaaa <fqdn>  → prints the first AAAA record (IPv6) or empty.
# Same authoritative-NS query strategy as dns_resolve_a.
dns_resolve_aaaa() {
    local fqdn="$1" ns
    ns=$(_dns_authoritative_ns "$fqdn")
    if [[ -n "$ns" ]]; then
        log_debug "dns: querying authoritative NS ${ns} for AAAA ${fqdn}"
        dig +short +time=5 +tries=2 @"$ns" AAAA "$fqdn" 2>/dev/null \
            | grep -E '^[0-9a-fA-F:]+$' \
            | head -1 || true
    else
        log_debug "dns: no authoritative NS found for ${fqdn}; falling back to system resolver"
        dig +short +time=5 +tries=2 AAAA "$fqdn" 2>/dev/null \
            | grep -E '^[0-9a-fA-F:]+$' \
            | head -1 || true
    fi
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
    if ! command -v dig >/dev/null 2>&1; then
        die "dig binary not found — install package 'dnsutils' (apt install -y dnsutils) and re-run. host-bootstrap.sh installs this automatically from f6f6f6f onward; if you're seeing this on a host bootstrapped earlier, re-run install.sh to apply the updated package list."
    fi
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

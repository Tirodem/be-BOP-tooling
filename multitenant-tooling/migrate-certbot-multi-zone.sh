#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# migrate-certbot-multi-zone.sh — one-shot migration for renewal configs
# whose --manual-{auth,cleanup}-hook still points at the deprecated
# certbot-ovh-*.sh scripts (renamed to certbot-dns-*.sh in the multi-
# provider refactor). Also seeds BEBOP_DNS_EXTRA_ZONES and the target
# provider's credentials in /etc/be-BOP-tooling/secrets.env so the new
# provider-agnostic hook can resolve legacy zones back to their provider.
#
# Trigger context: prior tooling was OVH-only (single OVH_DNS_ZONE); after
# the refactor the canonical zone lives in BEBOP_DNS_ZONE under
# DNS_PROVIDER. Any cert whose domain sits outside the canonical zone
# (typical after a provider migration) stops renewing until its zone is
# declared in BEBOP_DNS_EXTRA_ZONES.
#
# Idempotent: skips already-migrated .conf, keeps existing creds, does not
# duplicate zones already present in BEBOP_DNS_EXTRA_ZONES.
#
# Usage:
#   sudo migrate-certbot-multi-zone.sh --extra-zone <zone>:<provider> ...
#
# Example:
#   sudo migrate-certbot-multi-zone.sh --extra-zone pvh-labs.com:ovh

set -eEuo pipefail

readonly SCRIPT_NAME="migrate-certbot-multi-zone"

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
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"

: "${SECRETS_FILE:=/etc/be-BOP-tooling/secrets.env}"
: "${LE_RENEWAL_DIR:=/etc/letsencrypt/renewal}"
: "${TOOLING_HOOK_DIR:=/usr/local/share/be-BOP-tooling/hooks}"

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

usage() {
    cat <<EOF
${SCRIPT_NAME}.sh — migrate legacy certbot-ovh-* renewals to the provider-
agnostic certbot-dns-* hooks; register extra zones and prompt for missing
provider credentials.

Usage:
  sudo ${SCRIPT_NAME}.sh --extra-zone <zone>:<provider> [--extra-zone ...]

Options:
  --extra-zone <z>:<p>   Repeatable. Declare an extra (zone, provider) pair.
                         At least one required unless secrets.env already
                         lists every zone the orphan certs live in.
                         Provider ∈ { ovh, infomaniak }.
  -h, --help
EOF
}

EXTRA_ZONE_ARGS=()

while (( $# )); do
    case "$1" in
        --extra-zone) EXTRA_ZONE_ARGS+=("$2"); shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
done

require_privileges

# --- 1. Detect .conf files still pointing at certbot-ovh-*.sh -----------

mapfile -t ORPHAN_CONFS < <(
    run_privileged grep -lE '^(manual_auth_hook|manual_cleanup_hook)[[:space:]]*=.*certbot-ovh-' \
        "${LE_RENEWAL_DIR}"/*.conf 2>/dev/null || true
)

if (( ${#ORPHAN_CONFS[@]} == 0 )); then
    log_info "no .conf points at the deprecated certbot-ovh-* hooks — nothing to migrate"
    # Still purge the deprecated hook files if they linger on disk.
    for f in certbot-ovh-auth.sh certbot-ovh-cleanup.sh; do
        if run_privileged test -f "${TOOLING_HOOK_DIR}/${f}"; then
            run_privileged rm -f "${TOOLING_HOOK_DIR}/${f}"
            log_info "removed deprecated hook ${TOOLING_HOOK_DIR}/${f}"
        fi
    done
    exit 0
fi

log_info "found ${#ORPHAN_CONFS[@]} .conf pointing at certbot-ovh-* hooks:"
for c in "${ORPHAN_CONFS[@]}"; do
    log_info "  ${c}"
done

# --- 2. Load current secrets.env, plan the (zone, provider) map ---------

# Reading secrets.env in the current shell so we can inspect current OVH_*
# / INFOMANIAK_API_TOKEN / BEBOP_DNS_ZONE / BEBOP_DNS_EXTRA_ZONES without
# a second file read pass.
set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

declare -A ZONE_PROVIDER  # target state: zone → provider

# Seed with pairs already present in BEBOP_DNS_EXTRA_ZONES.
for pair in ${BEBOP_DNS_EXTRA_ZONES:-}; do
    z="${pair%%:*}"; p="${pair#*:}"
    [[ -n "$z" && -n "$p" && "$z" != "$p" ]] && ZONE_PROVIDER["$z"]="$p"
done

# Merge caller-supplied pairs (last-write-wins if the same zone was already
# in EXTRA_ZONES with a different provider — but that's an operator
# override and we honor it).
for pair in "${EXTRA_ZONE_ARGS[@]}"; do
    z="${pair%%:*}"; p="${pair#*:}"
    [[ -z "$z" || -z "$p" || "$z" == "$p" ]] && \
        die "invalid --extra-zone '${pair}' (expected zone:provider)"
    case "$p" in
        ovh|infomaniak) ;;
        *) die "--extra-zone '${pair}' uses unsupported provider '${p}' (want ovh|infomaniak)" ;;
    esac
    ZONE_PROVIDER["$z"]="$p"
done

# --- 3. Verify every orphan cert domain is covered by a known zone ------

COVERED_ZONES=()
[[ -n "${BEBOP_DNS_ZONE:-}" ]] && COVERED_ZONES+=("$BEBOP_DNS_ZONE")
for z in "${!ZONE_PROVIDER[@]}"; do COVERED_ZONES+=("$z"); done

# Build (cert_name → domain) rows via `certbot certificates`.
# awk emits one "<cert_name>\t<domain>" row per (cert, SAN) pair.
mapfile -t CERT_ROWS < <(
    run_privileged certbot certificates 2>/dev/null \
        | awk '/Certificate Name:/ {n=$3} /Domains:/ {for (i=2;i<=NF;i++) print n"\t"$i}'
)

uncovered=0
for conf in "${ORPHAN_CONFS[@]}"; do
    name="$(basename "${conf%.conf}")"
    for row in "${CERT_ROWS[@]}"; do
        row_name="${row%%$'\t'*}"
        [[ "$row_name" == "$name" ]] || continue
        dom="${row#*$'\t'}"
        matched=0
        for z in "${COVERED_ZONES[@]}"; do
            if [[ "$dom" == "$z" || "$dom" == *".${z}" ]]; then matched=1; break; fi
        done
        if (( ! matched )); then
            log_error "cert '${name}' domain '${dom}' is not covered by BEBOP_DNS_ZONE or planned extras"
            uncovered=1
        fi
    done
done

if (( uncovered )); then
    die "at least one orphan domain is not covered — pass the missing zone via --extra-zone <zone>:<provider>"
fi

# --- 4. Prompt for provider creds that are still empty ------------------

declare -A NEW_SECRETS
declare -A PROVIDERS_TOUCHED
for p in "${ZONE_PROVIDER[@]}"; do PROVIDERS_TOUCHED["$p"]=1; done

prompt_secret() {
    local var="$1" label="$2"
    local cur="${!var:-}"
    if [[ -n "$cur" ]]; then
        log_info "  ${var} already set — keeping current value"
        return 0
    fi
    printf '  %s: ' "$label" >&2
    IFS= read -rs val
    printf '\n' >&2
    [[ -z "$val" ]] && die "${var} is required"
    printf -v "$var" '%s' "$val"
    NEW_SECRETS["$var"]="$val"
}

for p in "${!PROVIDERS_TOUCHED[@]}"; do
    log_info "provider '${p}' credentials:"
    case "$p" in
        ovh)
            prompt_secret OVH_APPLICATION_KEY    "OVH_APPLICATION_KEY (silent)"
            prompt_secret OVH_APPLICATION_SECRET "OVH_APPLICATION_SECRET (silent)"
            prompt_secret OVH_CONSUMER_KEY       "OVH_CONSUMER_KEY (silent)"
            ;;
        infomaniak)
            prompt_secret INFOMANIAK_API_TOKEN "INFOMANIAK_API_TOKEN (silent)"
            ;;
    esac
done

# --- 5. Compose and persist the new secrets.env values ------------------

# Deterministic ordering so re-runs and diffs are stable.
mapfile -t SORTED_ZONES < <(printf '%s\n' "${!ZONE_PROVIDER[@]}" | sort)
NEW_EXTRA=""
for z in "${SORTED_ZONES[@]}"; do NEW_EXTRA+="${z}:${ZONE_PROVIDER[$z]} "; done
NEW_EXTRA="${NEW_EXTRA% }"
NEW_SECRETS[BEBOP_DNS_EXTRA_ZONES]="$NEW_EXTRA"

# Rewriting secrets.env one variable at a time via awk. We can't use
# `sed s|^KEY=.*|KEY="val"|` blindly because a token containing our
# delimiter would break the substitution; awk's -v is literal, no
# interpolation surprises. Any provider token that contains a literal `"`
# would still break the KEY="val" shape — we don't guard against that
# because none of the currently-supported providers issue such tokens.
update_secrets_var() {
    local var="$1" val="$2"
    local tmp
    tmp="$(mktemp)"
    run_privileged awk -v var="$var" -v val="$val" '
        BEGIN { done = 0 }
        $0 ~ "^" var "=" { print var "=\"" val "\""; done = 1; next }
        { print }
        END { if (!done) print var "=\"" val "\"" }
    ' "$SECRETS_FILE" > "$tmp"
    run_privileged install -m 0600 "$tmp" "$SECRETS_FILE"
    rm -f "$tmp"
}

for k in "${!NEW_SECRETS[@]}"; do
    update_secrets_var "$k" "${NEW_SECRETS[$k]}"
done
log_info "secrets.env updated: BEBOP_DNS_EXTRA_ZONES + provider credentials"

# --- 6. Rewrite the orphan .conf files to point at the new hooks --------

for c in "${ORPHAN_CONFS[@]}"; do
    run_privileged sed -i \
        -e 's|/certbot-ovh-auth\.sh|/certbot-dns-auth.sh|g' \
        -e 's|/certbot-ovh-cleanup\.sh|/certbot-dns-cleanup.sh|g' \
        "$c"
    log_info "migrated ${c}"
done

# --- 7. Remove the deprecated hook files if still on disk ---------------

for f in certbot-ovh-auth.sh certbot-ovh-cleanup.sh; do
    if run_privileged test -f "${TOOLING_HOOK_DIR}/${f}"; then
        run_privileged rm -f "${TOOLING_HOOK_DIR}/${f}"
        log_info "removed deprecated hook ${TOOLING_HOOK_DIR}/${f}"
    fi
done

log_info "migration complete — verify with:  sudo certbot renew --dry-run"

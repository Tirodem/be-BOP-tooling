#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# gh-rate-limit.sh — print the GitHub API rate-limit snapshot for the
# credentials currently configured in /etc/be-BOP-tooling/secrets.env.
#
# Authenticates with BEBOP_GITHUB_PAT when set (so the displayed quota is
# the 5000/h PAT pool used by the tooling), falls back to unauthenticated
# (60/h IP pool) when no PAT is configured.
#
# Output: one line for the "core" resource — that's what add-tenant /
# upgrade-* / tenant-cli all consume. Pass --raw for the full JSON.

set -eEuo pipefail

readonly SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
RAW=false

while (( $# )); do
    case "$1" in
        --raw)     RAW=true; shift ;;
        -h|--help)
            cat <<EOF
gh-rate-limit.sh — show GitHub API rate-limit for the configured PAT.

Usage:
  sudo gh-rate-limit.sh          # one-line "core" summary
  sudo gh-rate-limit.sh --raw    # full JSON from /rate_limit
EOF
            exit 0
            ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "gh-rate-limit: must run as root (sudo) to read $SECRETS_FILE" >&2
    exit 1
fi

if [[ ! -r "$SECRETS_FILE" ]]; then
    echo "gh-rate-limit: cannot read $SECRETS_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$SECRETS_FILE"

curl_args=(
    --silent --show-error --fail --location --max-time 15
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)
auth_label="unauth (IP quota, 60/h)"
if [[ -n "${BEBOP_GITHUB_PAT:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${BEBOP_GITHUB_PAT}")
    auth_label="PAT (5000/h)"
fi

resp=$(curl "${curl_args[@]}" https://api.github.com/rate_limit) \
    || { echo "gh-rate-limit: GitHub API query failed" >&2; exit 1; }

if [[ "$RAW" == "true" ]]; then
    printf '%s\n' "$resp" | jq .
    exit 0
fi

printf '%s\n' "$resp" | jq -r --arg auth "$auth_label" '
    .resources.core as $c |
    "core (\($auth)): \($c.used) / \($c.limit) used  · remaining \($c.remaining)  · resets at " +
    ($c.reset | strftime("%Y-%m-%d %H:%M:%SZ"))'

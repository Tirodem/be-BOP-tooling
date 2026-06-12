# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# freeze.sh — frozen-tenants list helpers.
#
# A "frozen" tenant is one that upgrade-all.sh (manual or via the nightly
# timer) must SKIP. Useful for probe environments / long-running debug
# tenants that mustn't be touched by routine fleet upgrades.
#
# Single-tenant manual runs (upgrade-tenant.sh <id>) IGNORE the freeze
# list — when the operator explicitly targets one tenant, they know what
# they're doing.
#
# Storage: a flat text file at $FREEZE_LIST_PATH (default
# /var/lib/be-BOP/frozen-tenants.txt), one tenant_id per line, # comments
# and blank lines ignored. Created on first use by freeze-tenant.sh.
#
# Source AFTER lib/log.sh.

[[ -n "${_BEBOP_FREEZE_SOURCED:-}" ]] && return 0
readonly _BEBOP_FREEZE_SOURCED=1

: "${FREEZE_LIST_PATH:=/var/lib/be-BOP/frozen-tenants.txt}"

# freeze_list_path → echoes the file path (for diagnostic messages).
freeze_list_path() { printf '%s\n' "$FREEZE_LIST_PATH"; }

# freeze_list_frozen → prints each frozen tenant_id (sorted, deduped).
# Empty output if the file doesn't exist or has no entries.
freeze_list_frozen() {
    [[ -r "$FREEZE_LIST_PATH" ]] || return 0
    awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} {print $1}' \
        "$FREEZE_LIST_PATH" | sort -u
}

# freeze_is_frozen <tenant_id> → returns 0 if frozen, 1 otherwise.
freeze_is_frozen() {
    local tenant="$1"
    [[ -r "$FREEZE_LIST_PATH" ]] || return 1
    freeze_list_frozen | grep -qFx -- "$tenant"
}

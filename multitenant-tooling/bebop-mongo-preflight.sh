#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# bebop-mongo-preflight.sh <tenant_id>
#
# Called as `ExecStartPre=+<this>` from bebop@<tenant>.service. Runs BEFORE
# the be-BOP node process, and guarantees that the tenant's mongod is:
#   1. running (starts it if not),
#   2. accepting connections,
#   3. initialised as a single-node replica set named rs0.
#
# If any step fails, exits non-zero — systemd then treats bebop@<tenant>
# as failed, which is the right outcome (bebop cannot function without a
# reachable, primary-elected replica set anyway).
#
# Idempotent + fast when the tenant is healthy: rs.status().ok is checked
# first and mongo_init_rs skips the initiate call when the RS is already
# primary.
#
# This exists because reaper / restart flows (tenant-cli.sh release
# install, `systemctl restart bebop@`, add-tenant reapply / reactivate)
# previously assumed the RS config was persistent. Empirically it isn't
# always (still investigating the root cause of RS loss on seedbox
# 2026-07-03). Putting the guard here — the single choke point every
# start passes through — closes the class of "bebop up but RS not
# primary → 30s Mongo timeout → EXIT" failures for all entry points at
# once.

set -eEuo pipefail

readonly SCRIPT_NAME="bebop-mongo-preflight"

TENANT_ID="${1:-}"
if [[ -z "$TENANT_ID" ]]; then
    echo "${SCRIPT_NAME}: tenant_id required as first arg" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "${SCRIPT_NAME}: cannot locate lib/ directory" >&2
    exit 1
fi

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
export BEBOP_TOOLING_SYSLOG_IDENT BEBOP_TOOLING_TENANT_ID
# Invoked with the '+' prefix in bebop@.service, i.e. as real root —
# skip sudo indirection.
export RUNNING_AS_ROOT=true

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"

MONGO_PORT=$(registry_get_field "$TENANT_ID" mongo_port)
if [[ -z "$MONGO_PORT" ]]; then
    die "no mongo_port for tenant '${TENANT_ID}' in ${REGISTRY_PATH}"
fi

# 1. Ensure mongod@<tenant> is up. `is-active` short-circuits to a no-op
#    start if it's already running.
if ! systemctl is-active --quiet "mongod@${TENANT_ID}.service"; then
    log_info "starting mongod@${TENANT_ID}.service..."
    systemctl start "mongod@${TENANT_ID}.service" \
        || die "could not start mongod@${TENANT_ID}"
fi

# 2. Wait for the port to accept connections. 30s is a generous ceiling
#    for a cold WiredTiger start on a small VDS.
mongo_wait_ready "$MONGO_PORT" 30 1 \
    || die "mongod@${TENANT_ID} did not become ready on 127.0.0.1:${MONGO_PORT}"

# 3. Initialise the single-node RS if needed. mongo_init_rs is idempotent
#    (checks rs.status().ok first) — normal cost on a healthy tenant is
#    one mongosh ping.
mongo_init_rs "$MONGO_PORT"

log_info "preflight OK for '${TENANT_ID}' (mongo port=${MONGO_PORT})"

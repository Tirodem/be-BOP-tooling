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

BEBOP_TOOLING_SYSLOG_IDENT="tooling-${SCRIPT_NAME}"
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

# Resolution order for the tenant's mongod port:
#   1. /etc/be-BOP-mongodb/<tid>/port.env — written at add-tenant phase 4,
#      i.e. BEFORE phase 12 that triggers this preflight. This is the
#      authoritative source, aligned with mongod@.service's own
#      EnvironmentFile.
#   2. Fallback to the registry, for callers that only ever wrote the
#      port there (older provisioning paths, or hand-maintained rows).
# We intentionally do NOT rely on the registry as primary source because
# registry_add runs at phase 14 (after service start), so a fresh
# provisioning would fail here on a stale registry read.
# 0. External MongoDB? The tenant's config.env is authoritative for WHERE
#    be-BOP connects, so that's what this preflight must check. When
#    MONGODB_URL names anything other than a loopback mongod — an
#    mongodb+srv:// cluster, or any remote host — there is no
#    mongod@<tenant> to start and no single-node rs0 to initiate: the
#    remote cluster owns its own topology. Verify the declared target is
#    reachable and stop there.
#
#    Everything below this block assumes the "one local mongod per tenant"
#    layout of the PoC. Without this branch, a tenant deliberately pointed
#    at an external cluster still had a local mongod demanded of it, and
#    bebop@<tenant> sat in start-pre until the wait timed out.
CONFIG_ENV="/etc/be-BOP/${TENANT_ID}/config.env"
DECLARED_URL=""
if [[ -r "$CONFIG_ENV" ]]; then
    DECLARED_URL=$(grep -oP '^MONGODB_URL=\K.*' "$CONFIG_ENV" 2>/dev/null || true)
fi

# Host of a mongodb:// or mongodb+srv:// URI: drop the scheme, drop any
# user:password@ prefix, then cut at the first : / or ? that follows.
_mongo_url_host() {
    local hostpart="$1"
    hostpart="${hostpart#mongodb+srv://}"
    hostpart="${hostpart#mongodb://}"
    hostpart="${hostpart##*@}"
    hostpart="${hostpart%%[:/?]*}"
    printf '%s' "$hostpart"
}

if [[ -n "$DECLARED_URL" ]]; then
    case "$(_mongo_url_host "$DECLARED_URL")" in
        127.0.0.1|localhost|::1|"")
            : # loopback — the local-mongod path below applies
            ;;
        *)
            log_info "preflight: external MongoDB declared in ${CONFIG_ENV} — not starting a local mongod for '${TENANT_ID}'"
            mongo_wait_ready_uri "$DECLARED_URL" 30 1 \
                || die "external MongoDB declared for '${TENANT_ID}' is not reachable"
            log_info "preflight OK for '${TENANT_ID}' (external MongoDB)"
            exit 0
            ;;
    esac
fi

PORT_ENV_FILE="/etc/be-BOP-mongodb/${TENANT_ID}/port.env"
if [[ -r "$PORT_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PORT_ENV_FILE"
fi
if [[ -z "${MONGO_PORT:-}" ]]; then
    MONGO_PORT=$(registry_get_field "$TENANT_ID" mongo_port)
fi
if [[ -z "${MONGO_PORT:-}" ]]; then
    die "no mongo_port for tenant '${TENANT_ID}' (checked ${PORT_ENV_FILE} and ${REGISTRY_PATH})"
fi

# 1. Ensure mongod@<tenant> is up. `is-active` short-circuits to a no-op
#    start if it's already running.
if ! systemctl is-active --quiet "mongod@${TENANT_ID}.service"; then
    log_info "starting mongod@${TENANT_ID}.service..."
    systemctl start "mongod@${TENANT_ID}.service" \
        || die "could not start mongod@${TENANT_ID}"
fi

# 2. Detect auth mode. When MONGO_AUTH_ARGS is set (from port.env), the
#    tenant has been migrated to authenticated mongod — an unauth port
#    ping would fail. We fetch the MONGODB_URL from the tenant's
#    config.env (contains SCRAM user:password) and use it as connection
#    target for the wait + RS-status check.
CONN_TARGET="$MONGO_PORT"
if [[ -n "${MONGO_AUTH_ARGS:-}" ]]; then
    CONFIG_ENV="/etc/be-BOP/${TENANT_ID}/config.env"
    if [[ -r "$CONFIG_ENV" ]]; then
        MONGODB_URL=$(grep -oP '^MONGODB_URL=\K.*' "$CONFIG_ENV" 2>/dev/null || true)
        if [[ -n "$MONGODB_URL" ]]; then
            CONN_TARGET="$MONGODB_URL"
            log_debug "preflight: auth-enabled, using authenticated URI from ${CONFIG_ENV}"
        fi
    fi
fi

# 3. Wait for connections. 30s is a generous ceiling for a cold
#    WiredTiger start on a small VDS.
mongo_wait_ready "$CONN_TARGET" 30 1 \
    || die "mongod@${TENANT_ID} did not become ready on 127.0.0.1:${MONGO_PORT}"

# 4. Verify or initialise the single-node RS.
#    - Unauth mode: mongo_init_rs is idempotent (checks status then
#      initiates if needed).
#    - Auth mode: we DON'T check rs.status() here. Rationale: the tenant's
#      SCRAM user has role=dbOwner scoped to its own DB, which does NOT
#      grant the `clusterMonitor` action required for `replSetGetStatus`
#      (i.e. rs.status()). Any check we make here would either need a
#      privileged user (widens attack surface) or fail with "unauthorized"
#      even on a perfectly healthy RS. The authenticated ping above
#      already confirms mongod is reachable + auth works; a broken RS
#      manifests as be-BOP timing out on connect (Mongo driver waits for
#      primary election via `replicaSet=rs0` in MONGODB_URL). That's the
#      pre-existing detection path; letting it flow through here is fine.
if [[ -z "${MONGO_AUTH_ARGS:-}" ]]; then
    mongo_init_rs "$MONGO_PORT"
fi

log_info "preflight OK for '${TENANT_ID}' (mongo port=${MONGO_PORT}, auth=${MONGO_AUTH_ARGS:+on})"

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# bebop-mail-relay-preflight.sh — ExecStartPre for bebop-mail-relay.service.
#
# Guarantees that the tooling MongoDB (mongod@tooling on 127.0.0.1:27100)
# is:
#   1. running (starts it if not),
#   2. accepting connections,
#   3. initialised as a single-node replica set named rs0.
#
# Mirrors bebop-mongo-preflight.sh (per-tenant mongod) — same three
# guarantees, one instance name difference. Failure blocks the mail-relay
# from starting, which is the right outcome (the relay cannot record
# sends without its database).

set -eEuo pipefail

readonly SCRIPT_NAME="bebop-mail-relay-preflight"
readonly TOOLING_SERVICE="bebop-tooling-mongodb.service"
readonly TOOLING_PORT=27100

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
export BEBOP_TOOLING_SYSLOG_IDENT
# Called with the '+' prefix in bebop-mail-relay.service — real root already.
export RUNNING_AS_ROOT=true

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/mongo.sh
source "$BEBOP_TOOLING_LIB_DIR/mongo.sh"

if ! systemctl is-active --quiet "$TOOLING_SERVICE"; then
    log_info "starting ${TOOLING_SERVICE}..."
    systemctl start "$TOOLING_SERVICE" \
        || die "could not start ${TOOLING_SERVICE}"
fi

mongo_wait_ready "$TOOLING_PORT" 30 1 \
    || die "${TOOLING_SERVICE} did not become ready on 127.0.0.1:${TOOLING_PORT}"

mongo_init_rs "$TOOLING_PORT"

log_info "mail-relay preflight OK (${TOOLING_SERVICE} port=${TOOLING_PORT})"

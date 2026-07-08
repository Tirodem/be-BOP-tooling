# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# mongo.sh — wrappers around per-tenant local mongod instances.
#
# Architecture (option B): one mongod per tenant, all bound to 127.0.0.1 on
# distinct local ports, each with its own dbPath at /var/lib/be-BOP-mongodb/<i>.
# Each instance is a single-node replica set named rs0 (Mongo requires a
# replica set for transactions and change streams).
#
# Tenant isolation is enforced at the process / filesystem level (DynamicUser
# + StateDirectory in mongod@.service), so mongod auth is NOT enabled. Each
# instance is its own bubble; no cross-tenant data path exists.
#
# Source AFTER lib/log.sh and lib/sudo.sh.
# Requires: mongosh (apt install mongodb-mongosh).

[[ -n "${_BEBOP_MONGO_SOURCED:-}" ]] && return 0
readonly _BEBOP_MONGO_SOURCED=1

: "${MONGO_RS_NAME:=rs0}"

# mongo_wait_ready <port_or_uri> [retries=60] [interval_sec=1]
# Polls db.adminCommand('ping') until mongod answers OK. Accepts either
# a port number (unauth localhost) or a full mongodb:// URI (post-auth).
# Returns 0 on success, 1 on timeout.
mongo_wait_ready() {
    local target="$1" retries="${2:-60}" interval="${3:-1}"
    _mongo_conn_argv "$target"
    local i
    for (( i=1; i<=retries; i++ )); do
        if mongosh --quiet "${MONGO_CONN_ARGV[@]}" --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            log_debug "mongo_wait_ready: ready (try ${i}/${retries})"
            return 0
        fi
        log_debug "mongo_wait_ready: not ready (try ${i}/${retries})"
        (( i < retries )) && sleep "$interval"
    done
    log_error "mongo_wait_ready: did not respond within $((retries * interval))s"
    return 1
}

# mongo_init_rs <port>
# Idempotent: skips if rs.status() is already OK on the target instance.
#
# All status probes use `|| true` because mongosh exits non-zero when the
# replica set is not yet initialised — without that guard, `set -e` +
# `pipefail` kill the surrounding script before we even reach rs.initiate().
mongo_init_rs() {
    local port="$1"
    local status
    status=$(mongosh --quiet --port "$port" --eval "rs.status().ok" 2>/dev/null \
        | tr -d '[:space:]' | tail -c 1 || true)
    if [[ "$status" == "1" ]]; then
        log_info "mongo: replica set on 127.0.0.1:${port} already initialised ✓"
        return 0
    fi
    log_info "mongo: initialising replica set on 127.0.0.1:${port}..."
    local cfg out
    cfg=$(printf '{_id: "%s", members: [{_id: 0, host: "127.0.0.1:%s"}]}' \
        "$MONGO_RS_NAME" "$port")
    out=$(mongosh --quiet --port "$port" --eval "rs.initiate(${cfg})" 2>&1) || true
    # rs.initiate() sometimes "fails" but actually succeeds; double-check by
    # polling rs.status().ok within a short window.
    local i
    for (( i=1; i<=10; i++ )); do
        status=$(mongosh --quiet --port "$port" --eval "rs.status().ok" 2>/dev/null \
            | tr -d '[:space:]' | tail -c 1 || true)
        [[ "$status" == "1" ]] && { log_info "mongo: rs OK on 127.0.0.1:${port}"; return 0; }
        sleep 1
    done
    die "mongo_init_rs: could not initialise replica set on 127.0.0.1:${port}: ${out}"
}

# mongo_build_url <port> <db_name>
# Outputs the unauth mongodb:// URL. Used only for pre-auth setup and
# unmigrated tenants — new tenants get an authed URL via
# mongo_build_url_authed instead.
mongo_build_url() {
    local port="$1" db="$2"
    printf 'mongodb://127.0.0.1:%s/%s?replicaSet=%s\n' "$port" "$db" "$MONGO_RS_NAME"
}

# mongo_generate_password
# 64 hex chars = 256 bits, URL-safe (no ':/@?#' collisions inside a
# MONGODB_URL). Enough entropy that a compromised tenant can't guess
# another tenant's password.
mongo_generate_password() {
    openssl rand -hex 32
}

# mongo_build_url_authed <port> <db_name> <user> <password>
# Outputs the authed MONGODB_URL. authSource=<db> because the user is
# created on the tenant's own DB (not on 'admin'), so the SCRAM
# handshake needs to look for creds there. Password is hex → no
# URI-reserved chars, no encoding needed.
mongo_build_url_authed() {
    local port="$1" db="$2" user="$3" pwd="$4"
    printf 'mongodb://%s:%s@127.0.0.1:%s/%s?authSource=%s&replicaSet=%s\n' \
        "$user" "$pwd" "$port" "$db" "$db" "$MONGO_RS_NAME"
}

# mongo_create_user <port> <db_name> <user> <password>
# Create (or reset the password of) a SCRAM user on <db_name> with role
# dbOwner scoped to <db_name>. Called with mongod running WITHOUT auth
# yet (fresh tenant) OR through the localhost exception (unauth-created
# instance getting its first user). Idempotent: existing user → password
# reset via updateUser; new user → createUser.
mongo_create_user() {
    local port="$1" db="$2" user="$3" pwd="$4"
    local db_json user_json pwd_json
    db_json=$(printf '%s' "$db" | jq -Rsa .)
    user_json=$(printf '%s' "$user" | jq -Rsa .)
    pwd_json=$(printf '%s' "$pwd" | jq -Rsa .)
    local js
    js=$(cat <<JS
const target = db.getSiblingDB(${db_json});
const existing = target.getUser(${user_json});
if (existing) {
    target.updateUser(${user_json}, { pwd: ${pwd_json}, roles: [{ role: "dbOwner", db: ${db_json} }] });
    print("mongo_create_user: reset password for existing user");
} else {
    target.createUser({ user: ${user_json}, pwd: ${pwd_json}, roles: [{ role: "dbOwner", db: ${db_json} }] });
    print("mongo_create_user: created new user");
}
JS
)
    if ! mongosh --quiet --port "$port" --eval "$js" >/dev/null 2>&1; then
        log_error "mongo_create_user: failed to create/update user '${user}' on db '${db}' at 127.0.0.1:${port}"
        return 1
    fi
    log_info "mongo: user '${user}' provisioned on db '${db}' (role=dbOwner, scoped to db)"
}

# mongo_wait_ready_uri <uri> [retries=60] [interval_sec=1]
# Authed variant of mongo_wait_ready. Poll ping via a full mongodb:// URI
# — used AFTER --auth has been enabled on the mongod instance, so
# --port would fail unauthenticated.
mongo_wait_ready_uri() {
    local uri="$1" retries="${2:-60}" interval="${3:-1}"
    local i
    for (( i=1; i<=retries; i++ )); do
        if mongosh --quiet "$uri" --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            log_debug "mongo_wait_ready_uri: ready (try ${i}/${retries})"
            return 0
        fi
        log_debug "mongo_wait_ready_uri: not ready (try ${i}/${retries})"
        (( i < retries )) && sleep "$interval"
    done
    log_error "mongo_wait_ready_uri: did not respond within $((retries * interval))s"
    return 1
}

# _mongo_conn_argv <port_or_uri>
# Populates the global array MONGO_CONN_ARGV with the right mongosh
# connection args for either form. When <arg> looks like mongodb://…
# it's used as a URI; otherwise it's treated as a port (unauth
# localhost). Callers use it as:
#   _mongo_conn_argv "$conn"
#   mongosh --quiet "${MONGO_CONN_ARGV[@]}" --eval '...'
# This lets the operational helpers below transparently accept a port
# (unauth, backward-compat, or pre-auth setup) or a full URI (post-auth).
_mongo_conn_argv() {
    MONGO_CONN_ARGV=()
    if [[ "$1" == mongodb://* ]]; then
        MONGO_CONN_ARGV=("$1")
    else
        MONGO_CONN_ARGV=(--port "$1")
    fi
}

# mongo_db_drop <port_or_uri> <db_name>
# Drops the named DB. Idempotent (Mongo returns ok even if the DB
# doesn't exist).
mongo_db_drop() {
    local target="$1" db="$2"
    _mongo_conn_argv "$target"
    if ! mongosh --quiet "${MONGO_CONN_ARGV[@]}" --eval \
        "db.getSiblingDB('${db}').dropDatabase()" >/dev/null 2>&1; then
        log_warn "mongo_db_drop: dropDatabase('${db}') returned non-zero"
        return 1
    fi
    log_info "mongo: dropped database '${db}'"
}

# mongo_dump_db <port_or_uri> <db_name> <out_dir>
# Runs mongodump for a single DB into <out_dir>. Caller creates <out_dir>
# first. Requires mongodump (mongodb-database-tools).
mongo_dump_db() {
    local target="$1" db="$2" out="$3"
    if ! command -v mongodump >/dev/null 2>&1; then
        log_warn "mongo_dump_db: mongodump not installed (apt install mongodb-database-tools); skipping"
        return 1
    fi
    log_info "mongo: mongodump db='${db}' → ${out}"
    local -a conn_argv
    if [[ "$target" == mongodb://* ]]; then
        conn_argv=(--uri "$target")
    else
        conn_argv=(--port "$target")
    fi
    mongodump --quiet "${conn_argv[@]}" --db "$db" --out "$out"
}

# mongo_restore_db <port_or_uri> <db_name> <dump_dir>
# Restores a single DB from a mongodump output dir. The caller drops
# the target DB first if a clean restore is wanted. Looks for
# <dump_dir>/<db_name>/ (mongodump's default layout).
mongo_restore_db() {
    local target="$1" db="$2" dump_dir="$3"
    if ! command -v mongorestore >/dev/null 2>&1; then
        die "mongo_restore_db: mongorestore not installed (apt install mongodb-database-tools)"
    fi
    local db_subdir="${dump_dir}/${db}"
    if [[ ! -d "$db_subdir" ]]; then
        die "mongo_restore_db: dump dir for '${db}' not found at ${db_subdir}"
    fi
    log_info "mongo: mongorestore db='${db}' ← ${db_subdir}"
    local -a conn_argv
    if [[ "$target" == mongodb://* ]]; then
        conn_argv=(--uri "$target")
    else
        conn_argv=(--port "$target")
    fi
    mongorestore --quiet "${conn_argv[@]}" --db "$db" "$db_subdir"
}

# mongo_runtime_config_upsert <port> <db_name> <key> <value> <lock>
# Upserts a single runtimeConfig document:
#   { _id: <key>, data: <value>, [lock: true,] createdAt, updatedAt }
# <lock> must be "true" or "false". When false, the lock field is $unset so
# the flag is reversible (locked → unlocked on next deploy with the non-lock
# variant of the flag).
# Requires: mongosh + jq (already host deps).
mongo_runtime_config_upsert() {
    local target="$1" db="$2" key="$3" value="$4" lock="$5"
    if [[ "$lock" != "true" && "$lock" != "false" ]]; then
        log_error "mongo_runtime_config_upsert: lock must be true|false (got '${lock}')"
        return 1
    fi
    _mongo_conn_argv "$target"
    local key_json value_json db_json
    key_json=$(printf '%s' "$key" | jq -Rsa .)
    value_json=$(printf '%s' "$value" | jq -Rsa .)
    db_json=$(printf '%s' "$db" | jq -Rsa .)
    local update
    if [[ "$lock" == "true" ]]; then
        update=$(printf '{ $set: { data: %s, lock: true, updatedAt: now }, $setOnInsert: { createdAt: now } }' "$value_json")
    else
        update=$(printf '{ $set: { data: %s, updatedAt: now }, $setOnInsert: { createdAt: now }, $unset: { lock: "" } }' "$value_json")
    fi
    local js
    js=$(printf 'const now = new Date(); db.getSiblingDB(%s).runtimeConfig.updateOne({_id: %s}, %s, {upsert: true});' \
        "$db_json" "$key_json" "$update")
    if ! mongosh --quiet "${MONGO_CONN_ARGV[@]}" --eval "$js" >/dev/null 2>&1; then
        log_error "mongo_runtime_config_upsert: failed for ${key} on ${db}"
        return 1
    fi
    log_info "mongo: runtimeConfig.${key} upserted (lock=${lock})"
}

# mongo_runtime_config_upsert_obj <port> <db_name> <key> <json_value> <lock>
# Variant of mongo_runtime_config_upsert that stores <json_value> as a parsed
# Mongo document (object, array, number, …) instead of a JSON string. Used for
# nested runtimeConfig entries like `smtp` which be-BOP reads via Object.assign
# (so the value MUST be an actual object, not a stringified one).
# <json_value> must be a syntactically valid JSON literal; the caller is
# responsible for producing it (e.g. via `jq -n '{host: $h, port: ($p | tonumber)}'`).
mongo_runtime_config_upsert_obj() {
    local target="$1" db="$2" key="$3" json_value="$4" lock="$5"
    if [[ "$lock" != "true" && "$lock" != "false" ]]; then
        log_error "mongo_runtime_config_upsert_obj: lock must be true|false (got '${lock}')"
        return 1
    fi
    if ! printf '%s' "$json_value" | jq -e . >/dev/null 2>&1; then
        log_error "mongo_runtime_config_upsert_obj: invalid JSON for ${key}"
        return 1
    fi
    _mongo_conn_argv "$target"
    local key_json db_json
    key_json=$(printf '%s' "$key" | jq -Rsa .)
    db_json=$(printf '%s' "$db" | jq -Rsa .)
    local update
    if [[ "$lock" == "true" ]]; then
        update=$(printf '{ $set: { data: %s, lock: true, updatedAt: now }, $setOnInsert: { createdAt: now } }' "$json_value")
    else
        update=$(printf '{ $set: { data: %s, updatedAt: now }, $setOnInsert: { createdAt: now }, $unset: { lock: "" } }' "$json_value")
    fi
    local js
    js=$(printf 'const now = new Date(); db.getSiblingDB(%s).runtimeConfig.updateOne({_id: %s}, %s, {upsert: true});' \
        "$db_json" "$key_json" "$update")
    if ! mongosh --quiet "${MONGO_CONN_ARGV[@]}" --eval "$js" >/dev/null 2>&1; then
        log_error "mongo_runtime_config_upsert_obj: failed for ${key} on ${db}"
        return 1
    fi
    log_info "mongo: runtimeConfig.${key} upserted as object (lock=${lock})"
}

# mongo_collection_upsert_doc <target> <db> <collection> <doc_json>
# Upsert an arbitrary document into <collection>, keyed by its `_id` field.
# The doc's own fields are $set; `createdAt` is $setOnInsert; `updatedAt`
# is stamped with now. Used by add-tenant.sh apply_collection_seeds to
# materialise the `seeds` sub-object of a deploy-default.json profile
# (typically vatProfiles, deliveryProfiles, and other reference tables
# that live in dedicated collections rather than runtimeConfig).
#
# `_id` handling (bash-side rewrite, then mongosh EJSON.parse):
#   { "$oid_from": "<slug>" }  →  ObjectId(sha256(<slug>)[0..24])
#       Deterministic derivation from a human-readable slug. Same slug
#       always yields the same ObjectId, so re-seeds are idempotent
#       (upsert matches the existing _id) and be-BOP's admin path
#       (`new ObjectId(_id)`) works because we stored a real ObjectId.
#   { "$oid": "<24-hex>" }     →  ObjectId(<24-hex>) via EJSON literal
#   "<any string>"             →  kept as-is (string _id; only safe for
#                                 collections that don't do `new ObjectId(_id)`)
#   <number>                   →  kept as-is
#
# Required: doc_json MUST contain "_id". Other EJSON extended types
# (ISODate, NumberDecimal…) pass through EJSON.parse as-is if the caller
# writes them, but tooling doesn't derive them.
mongo_collection_upsert_doc() {
    local target="$1" db="$2" coll="$3" doc="$4"
    if ! printf '%s' "$doc" | jq -e 'has("_id")' >/dev/null 2>&1; then
        log_error "mongo_collection_upsert_doc: doc missing _id: ${doc}"
        return 1
    fi
    # Detect { "$oid_from": <slug> } and rewrite to { "$oid": <hash24> }.
    # sha256sum output = "<hex64>  -\n"; awk grabs field 1, cut narrows to 24.
    if printf '%s' "$doc" | jq -e '._id | type == "object" and has("$oid_from")' >/dev/null 2>&1; then
        local slug hash24
        slug=$(printf '%s' "$doc" | jq -r '._id["$oid_from"]')
        hash24=$(printf '%s' "$slug" | sha256sum | awk '{print $1}' | cut -c1-24)
        doc=$(printf '%s' "$doc" | jq --arg h "$hash24" '._id = {"$oid": $h}')
        log_info "mongo: ${coll} derived _id ObjectId(\"${hash24}\") from \"${slug}\""
    fi
    _mongo_conn_argv "$target"
    local db_json coll_json doc_b64
    db_json=$(printf '%s' "$db" | jq -Rsa .)
    coll_json=$(printf '%s' "$coll" | jq -Rsa .)
    doc_b64=$(printf '%s' "$doc" | base64 -w0)
    # Base64 → we don't fight quote escaping inside mongosh --eval.
    # atob is a Node global (mongosh runs on Node 16+). EJSON.parse
    # resolves { "$oid": "..." } → ObjectId, { "$date": ... } → Date, etc.
    local js
    js=$(cat <<JS
const doc = EJSON.parse(atob("${doc_b64}"));
const now = new Date();
const _id = doc._id;
delete doc._id;
doc.updatedAt = now;
db.getSiblingDB(${db_json}).getCollection(${coll_json}).updateOne(
    { _id: _id },
    { \$set: doc, \$setOnInsert: { createdAt: now } },
    { upsert: true }
);
JS
)
    if ! mongosh --quiet "${MONGO_CONN_ARGV[@]}" --eval "$js" >/dev/null 2>&1; then
        log_error "mongo_collection_upsert_doc: failed on ${db}.${coll} (doc=${doc})"
        return 1
    fi
    log_info "mongo: ${coll} doc upserted"
}

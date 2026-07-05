#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# mail-relay.py — fake SMTP shim for be-BOP tenant outbound mail.
#
# Milestone 1 (this file): accepts SMTP connections on 127.0.0.1:2525,
# enforces AUTH LOGIN/PLAIN before MAIL FROM, logs each accepted delivery
# to SQLite, and returns 250 OK. NO forwarding yet, NO TLS, NO rate limits.
#
# Design decisions locked in the design phase (see project discussion):
#   - Per-VDS colocated relay (127.0.0.1 loopback only, one relay per VDS)
#   - Python + aiosmtpd (consistency with lib/test-tenant-api.py)
#   - SQLite state under /var/lib/be-BOP/mail-relay/state.db
#   - Master provider credential in /etc/be-BOP-tooling/secrets.env
#   - Provider-agnostic: this daemon knows nothing specific about Scaleway
#     until milestone 3 (forwarding), and even then Scaleway is one config
#     value away from Mailgun/Postmark.
#
# The auth model: each tenant has a row in `tenants` (id, bcrypt_pass,
# quotas, mail_status). SMTP AUTH LOGIN/PLAIN checks the presented user +
# password against that row. Cross-tenant impersonation is closed by the
# `authed_user == From subdomain` enforcement (added in milestone 4).

from __future__ import annotations

import asyncio
import base64
import logging
import os
import signal
import sqlite3
import sys
from contextlib import contextmanager
from pathlib import Path

try:
    import bcrypt
except ImportError:
    print("mail-relay: python3-bcrypt is required (apt install python3-bcrypt)",
          file=sys.stderr)
    sys.exit(1)

try:
    from aiosmtpd.controller import Controller
    from aiosmtpd.smtp import SMTP as SMTPServer, AuthResult, LoginPassword
except ImportError:
    print("mail-relay: python3-aiosmtpd is required (apt install python3-aiosmtpd)",
          file=sys.stderr)
    sys.exit(1)


# --- Paths & config ---------------------------------------------------------

# StateDirectory=be-BOP/mail-relay in the systemd unit maps to this path
# and belongs to the DynamicUser. We can therefore assume RW access.
STATE_DIR = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/be-BOP/mail-relay"))
DB_PATH = STATE_DIR / "state.db"

# Loopback-only listen socket. Any process running on the same VDS can
# reach this — cross-tenant safety is guaranteed by SMTP AUTH + (later)
# From-subdomain enforcement, not by network isolation.
LISTEN_HOST = os.environ.get("BEBOP_MAIL_RELAY_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("BEBOP_MAIL_RELAY_PORT", "2525"))

LOG = logging.getLogger("bebop-mail-relay")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)


# --- SQLite schema ---------------------------------------------------------

# One row per tenant. mail_status matches the values written by add-tenant.sh
# in the registry (`active` / `pending` / `failed` per milestone 5 design).
# Quotas can be overridden per tenant via CLI (milestone 2); when NULL, the
# daemon falls back to the compiled-in defaults below.
SCHEMA = """
CREATE TABLE IF NOT EXISTS tenants (
    tenant_id       TEXT PRIMARY KEY,
    pass_hash       TEXT NOT NULL,
    hard_cap_10min  INTEGER,
    hard_cap_24h    INTEGER,
    hard_cap_month  INTEGER,
    soft_alert_10min INTEGER,
    soft_alert_24h  INTEGER,
    soft_alert_month INTEGER,
    mail_status     TEXT NOT NULL DEFAULT 'active',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS send_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    tenant_id   TEXT NOT NULL,
    sent_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    recipient   TEXT NOT NULL,
    size_bytes  INTEGER NOT NULL DEFAULT 0,
    status      TEXT NOT NULL,       -- accepted | rejected-quota | rejected-scaleway
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id)
);

CREATE INDEX IF NOT EXISTS idx_send_log_tenant_sent
    ON send_log (tenant_id, sent_at);

-- One row per (tenant, window) tracking when we last raised a soft alert on
-- that window. Used in milestone 4 to implement the cool-down: don't spam
-- Zulip while a tenant sits above the soft threshold.
CREATE TABLE IF NOT EXISTS alert_state (
    tenant_id   TEXT NOT NULL,
    window_kind TEXT NOT NULL,       -- 10min | 24h | month
    last_alert_at TEXT,
    PRIMARY KEY (tenant_id, window_kind),
    FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id)
);
"""


@contextmanager
def db_conn():
    """Short-lived connection. isolation_level=None → autocommit; each
    statement is its own tx. Enough for a low-QPS shim; we can revisit if
    contention shows up in metrics."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH), isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA foreign_keys = ON;")
    try:
        yield conn
    finally:
        conn.close()


def init_schema() -> None:
    with db_conn() as conn:
        conn.executescript(SCHEMA)
    LOG.info("state db ready at %s", DB_PATH)


# --- Auth backend ----------------------------------------------------------

def _lookup_tenant_pass_hash(tenant_id: str) -> bytes | None:
    with db_conn() as conn:
        row = conn.execute(
            "SELECT pass_hash FROM tenants WHERE tenant_id = ? AND mail_status = 'active'",
            (tenant_id,),
        ).fetchone()
    if row is None:
        return None
    return row["pass_hash"].encode("utf-8")


def auth_check(server, session, envelope, mechanism, auth_data) -> AuthResult:
    """Called by aiosmtpd for LOGIN and PLAIN. Both mechanisms provide the
    credentials as a LoginPassword named tuple (login, password bytes)."""
    if not isinstance(auth_data, LoginPassword):
        LOG.warning("auth: unsupported auth data type %r", type(auth_data))
        return AuthResult(success=False, handled=True)
    tenant_id = auth_data.login.decode("utf-8", errors="replace").strip()
    if not tenant_id:
        return AuthResult(success=False, handled=True)
    stored_hash = _lookup_tenant_pass_hash(tenant_id)
    if stored_hash is None:
        LOG.info("auth: unknown or inactive tenant %r from %s",
                 tenant_id, session.peer)
        # Constant-time-ish: still run one bcrypt to smooth out timing.
        # Uses a throwaway hash so the operation actually happens.
        bcrypt.checkpw(auth_data.password, bcrypt.hashpw(b"x", bcrypt.gensalt(4)))
        return AuthResult(success=False, handled=True)
    if not bcrypt.checkpw(auth_data.password, stored_hash):
        LOG.info("auth: bad password for tenant %r from %s",
                 tenant_id, session.peer)
        return AuthResult(success=False, handled=True)
    LOG.info("auth: tenant %r authenticated from %s", tenant_id, session.peer)
    # Stash the authenticated tenant on the session so the handler can
    # read it in later hooks (used by From-subdomain enforcement in
    # milestone 4). aiosmtpd exposes AuthResult.auth_data for this exact
    # purpose.
    return AuthResult(success=True, handled=True, auth_data=tenant_id)


# --- SMTP handler ----------------------------------------------------------

class RelayHandler:
    """Milestone 1 behaviour: on DATA, log the message metadata to send_log
    with status='accepted' and return 250 OK. No forwarding, no size limit
    beyond aiosmtpd defaults.

    All the interesting logic (quotas, From-subdomain check, forwarding to
    Scaleway) lands in later milestones. This is the plumbing skeleton."""

    async def handle_MAIL(self, server, session, envelope, address, mail_options):
        if session.auth_data is None:
            return "530 5.7.0 Authentication required"
        envelope.mail_from = address
        return "250 OK"

    async def handle_RCPT(self, server, session, envelope, address, rcpt_options):
        if session.auth_data is None:
            return "530 5.7.0 Authentication required"
        envelope.rcpt_tos.append(address)
        return "250 OK"

    async def handle_DATA(self, server, session, envelope):
        if session.auth_data is None:
            return "530 5.7.0 Authentication required"
        tenant_id = session.auth_data
        size = len(envelope.original_content or b"")
        LOG.info(
            "mail accepted (milestone 1: no forwarding) tenant=%s from=%s to=%r size=%d",
            tenant_id, envelope.mail_from, envelope.rcpt_tos, size,
        )
        with db_conn() as conn:
            for rcpt in envelope.rcpt_tos:
                conn.execute(
                    "INSERT INTO send_log (tenant_id, recipient, size_bytes, status) "
                    "VALUES (?, ?, ?, 'accepted')",
                    (tenant_id, rcpt, size),
                )
        return "250 OK"


# --- Controller wiring -----------------------------------------------------

class AuthController(Controller):
    """Controller subclass that hands an authenticator to the SMTP factory.
    aiosmtpd's default Controller.factory() constructs SMTP() without the
    auth hooks, so we override to inject them."""

    def factory(self):
        return SMTPServer(
            self.handler,
            authenticator=auth_check,
            auth_required=True,
            auth_require_tls=False,  # milestone 1: no TLS yet (see file header)
            hostname="bebop-mail-relay",
        )


async def _run_forever(controller: AuthController) -> None:
    LOG.info("listening on %s:%d (milestone 1: no TLS, no forwarding)",
             LISTEN_HOST, LISTEN_PORT)
    stop = asyncio.Event()

    def _signal(*_):
        LOG.info("stop signal received, shutting down")
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _signal)

    await stop.wait()
    controller.stop()
    LOG.info("stopped")


def main() -> int:
    init_schema()
    controller = AuthController(
        RelayHandler(),
        hostname=LISTEN_HOST,
        port=LISTEN_PORT,
    )
    controller.start()
    try:
        asyncio.run(_run_forever(controller))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

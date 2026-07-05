#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# mail-relay.py — fake SMTP shim for be-BOP tenant outbound mail.
#
# Milestones covered by this file:
#   1. AUTH LOGIN/PLAIN + SQLite state (tenants / send_log / alert_state)
#   3. Sync forwarding to the upstream transactional provider (Scaleway TEM
#      by config; provider-agnostic by design), retry policy 5s / 15s / 30s
#      on 4xx or connection errors, 5xx propagated directly to be-BOP.
#
# Design decisions locked in the design phase (see project discussion):
#   - Per-VDS colocated relay (127.0.0.1 loopback only, one relay per VDS)
#   - Python + aiosmtpd (consistency with lib/test-tenant-api.py)
#   - SQLite state under /var/lib/be-BOP/mail-relay/state.db
#   - Upstream credential in /etc/be-BOP-tooling/secrets.env
#   - Provider-agnostic: swap MAIL_RELAY_UPSTREAM_* to change target.
#
# The auth model: each tenant has a row in `tenants` (id, bcrypt_pass,
# quotas, mail_status). SMTP AUTH LOGIN/PLAIN checks the presented user +
# password against that row. Cross-tenant impersonation is closed by the
# `authed_user == From subdomain` enforcement (milestone 4).
#
# Failure semantics — be-BOP does NOT retry (verified against
# src/lib/server/locks/email-notifications.ts). Any error we surface to
# be-BOP is terminal for that message. Consequences:
#   * Transient upstream 4xx / connection errors → we retry INTERNALLY
#     up to 3 times with back-off (5s, 15s, 30s), total budget ~50s.
#     Well within nodemailer's default socketTimeout (~600s).
#   * Upstream 5xx → passed through unchanged; be-BOP marks failed.
#   * All retries exhausted → last error surfaced to be-BOP; the message
#     is lost from be-BOP's point of view. Ops sees it in /admin/email.

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

try:
    import aiosmtplib
except ImportError:
    print("mail-relay: python3-aiosmtplib is required (apt install python3-aiosmtplib)",
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

# --- Upstream provider (Scaleway TEM by config) ----------------------------

UPSTREAM_HOST = os.environ.get("MAIL_RELAY_UPSTREAM_HOST", "").strip()
UPSTREAM_PORT = int(os.environ.get("MAIL_RELAY_UPSTREAM_PORT", "587"))
UPSTREAM_USER = os.environ.get("MAIL_RELAY_UPSTREAM_USER", "").strip()
UPSTREAM_PASSWORD = os.environ.get("MAIL_RELAY_UPSTREAM_PASSWORD", "")


def _truthy(s: str) -> bool:
    return s.strip().lower() in ("true", "1", "yes", "on")


UPSTREAM_SMTPS = _truthy(os.environ.get("MAIL_RELAY_UPSTREAM_SMTPS", ""))
UPSTREAM_CONFIGURED = bool(UPSTREAM_HOST and UPSTREAM_USER and UPSTREAM_PASSWORD)

# Retry policy (see design decisions). back-off in SECONDS between attempts;
# the total wall-clock ceiling is sum() + per-connection latency.
RETRY_BACKOFFS = (5, 15, 30)  # attempts 2, 3, and 4 wait these before firing


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


# --- Upstream forwarding ---------------------------------------------------

class UpstreamResult:
    """Discriminated result of a single forwarding attempt. `code` is the
    SMTP reply code as reported by aiosmtplib (int) or None on transport
    failure. `retryable` = should we try again per policy."""
    __slots__ = ("code", "message", "retryable")

    def __init__(self, code: int | None, message: str, retryable: bool):
        self.code = code
        self.message = message
        self.retryable = retryable


async def _forward_once(envelope) -> UpstreamResult:
    """Single attempt at handing the message to the upstream provider."""
    try:
        # aiosmtplib.send() opens, EHLOs, STARTTLS if requested, AUTHs,
        # sends, and QUITs — all in one call. Cheaper than pooling for
        # our expected QPS.
        response = await aiosmtplib.send(
            envelope.original_content or b"",
            sender=envelope.mail_from,
            recipients=envelope.rcpt_tos,
            hostname=UPSTREAM_HOST,
            port=UPSTREAM_PORT,
            username=UPSTREAM_USER,
            password=UPSTREAM_PASSWORD,
            start_tls=(not UPSTREAM_SMTPS),
            use_tls=UPSTREAM_SMTPS,
            timeout=45,
        )
        # aiosmtplib.send returns (errors_dict, response_str). Success ==
        # empty errors dict.
        errors, msg = response
        if errors:
            # Per-recipient rejections. We treat any per-rcpt error as a
            # message-level failure (be-BOP sends one recipient per row
            # anyway — verified against email.ts).
            worst = max((code for code, _ in errors.values()), default=550)
            retryable = 400 <= worst < 500
            return UpstreamResult(worst, f"per-recipient errors: {errors}", retryable)
        return UpstreamResult(250, msg or "OK", retryable=False)
    except aiosmtplib.SMTPResponseException as exc:
        retryable = 400 <= exc.code < 500
        return UpstreamResult(exc.code, exc.message, retryable=retryable)
    except (aiosmtplib.SMTPConnectError, aiosmtplib.SMTPServerDisconnected,
            aiosmtplib.SMTPTimeoutError, ConnectionError, OSError, asyncio.TimeoutError) as exc:
        # Transport-level failures — treat as retryable temp fails.
        return UpstreamResult(None, f"{type(exc).__name__}: {exc}", retryable=True)


async def forward_with_retry(envelope) -> UpstreamResult:
    """Retry policy: try once, then each entry in RETRY_BACKOFFS is the wait
    BEFORE the next attempt. Stops on first non-retryable result (2xx or
    5xx), or when out of budget."""
    last = await _forward_once(envelope)
    for wait in RETRY_BACKOFFS:
        if not last.retryable:
            return last
        LOG.warning(
            "upstream forward failed (retryable): code=%s msg=%s — retrying in %ds",
            last.code, last.message, wait,
        )
        await asyncio.sleep(wait)
        last = await _forward_once(envelope)
    return last


# --- SMTP handler ----------------------------------------------------------

class RelayHandler:
    """Accepts messages after AUTH, forwards synchronously to the upstream
    provider (Scaleway TEM in V1), logs the outcome per recipient in
    send_log. If MAIL_RELAY_UPSTREAM_* is not configured (empty in
    secrets.env), the handler runs in log-only mode: sends are accepted
    and recorded but not forwarded, useful for pre-provider dev."""

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

        if not UPSTREAM_CONFIGURED:
            # Log-only fallback (pre-provider onboarding). Same semantic
            # as milestone 1: accept, record, return 250. Ops sees this
            # in journalctl and adds provider creds in secrets.env when
            # ready.
            LOG.info(
                "log-only (no upstream) tenant=%s from=%s to=%r size=%d",
                tenant_id, envelope.mail_from, envelope.rcpt_tos, size,
            )
            self._insert_send_log(tenant_id, envelope, size, "log-only")
            return "250 OK"

        result = await forward_with_retry(envelope)
        # Map internal result to SMTP wire status returned to be-BOP.
        if result.code is not None and 200 <= result.code < 300:
            status = "sent-upstream"
            reply = "250 OK"
            LOG.info(
                "forwarded tenant=%s from=%s to=%r size=%d code=%s",
                tenant_id, envelope.mail_from, envelope.rcpt_tos, size, result.code,
            )
        elif result.code is not None and 500 <= result.code < 600:
            status = "failed-upstream-5xx"
            reply = f"{result.code} {result.message[:200]}"
            LOG.warning(
                "5xx from upstream tenant=%s code=%s msg=%s",
                tenant_id, result.code, result.message,
            )
        else:
            status = "failed-upstream-4xx" if result.code else "failed-upstream-transport"
            code_out = result.code or 451  # 451 = "requested action aborted, try later"
            reply = f"{code_out} {result.message[:200]}"
            LOG.warning(
                "upstream failed after retries tenant=%s code=%s msg=%s",
                tenant_id, result.code, result.message,
            )
        self._insert_send_log(tenant_id, envelope, size, status)
        return reply

    def _insert_send_log(self, tenant_id, envelope, size, status):
        with db_conn() as conn:
            for rcpt in envelope.rcpt_tos:
                conn.execute(
                    "INSERT INTO send_log (tenant_id, recipient, size_bytes, status) "
                    "VALUES (?, ?, ?, ?)",
                    (tenant_id, rcpt, size, status),
                )


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
    if UPSTREAM_CONFIGURED:
        LOG.info(
            "listening on %s:%d — upstream: %s:%d (%s) as %s",
            LISTEN_HOST, LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT,
            "SMTPS" if UPSTREAM_SMTPS else "STARTTLS", UPSTREAM_USER,
        )
    else:
        LOG.warning(
            "listening on %s:%d — MAIL_RELAY_UPSTREAM_* not configured, "
            "running in log-only mode (sends recorded but NOT forwarded)",
            LISTEN_HOST, LISTEN_PORT,
        )
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

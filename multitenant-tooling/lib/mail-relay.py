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
import json
import logging
import os
import signal
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timezone
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

# --- Quotas & alerting -----------------------------------------------------

# Default caps per tenant. Overridable per-tenant via mail-relay-ctl set-quota.
# Rationale: 2€/tenant/month Scaleway ceiling (8000 mails at Essential
# pay-as-you-go) is the true budget guard; 10min/24h are anti-burst and
# anti-slow-burst nets around that.
DEFAULT_HARD_CAP_10MIN = 100
DEFAULT_SOFT_ALERT_10MIN = 50
DEFAULT_HARD_CAP_24H = 500
DEFAULT_SOFT_ALERT_24H = 250
DEFAULT_HARD_CAP_MONTH = 8000
DEFAULT_SOFT_ALERT_MONTH = 4000

# Cool-down between two soft-alert notifications for the same (tenant,
# window). Prevents Zulip spam while a tenant sits above threshold.
COOLDOWN_10MIN_SECONDS = 600      # 10 minutes
COOLDOWN_24H_SECONDS = 21600      # 6 hours
COOLDOWN_MONTH_SECONDS = 86400    # 24 hours

# Windows are indexed by short name across the schema, CLI, and logs.
# Keep this list ordered from finest to coarsest — get_window_counters()
# returns them in this order.
WINDOW_DEFS = (
    ("10min", "-10 minutes", DEFAULT_HARD_CAP_10MIN, DEFAULT_SOFT_ALERT_10MIN,
        COOLDOWN_10MIN_SECONDS, "hard_cap_10min", "soft_alert_10min"),
    ("24h",   "-1 day",      DEFAULT_HARD_CAP_24H,   DEFAULT_SOFT_ALERT_24H,
        COOLDOWN_24H_SECONDS,   "hard_cap_24h",  "soft_alert_24h"),
    ("month", "-30 days",    DEFAULT_HARD_CAP_MONTH, DEFAULT_SOFT_ALERT_MONTH,
        COOLDOWN_MONTH_SECONDS, "hard_cap_month","soft_alert_month"),
)

# --- Anti-bruteforce on AUTH ----------------------------------------------

# Sliding window per source-IP. In-memory only; a process restart wipes
# the counters (acceptable — an attacker still hits the window on restart).
AUTH_FAIL_WINDOW_SECONDS = 60
AUTH_FAIL_THRESHOLD = 10
AUTH_FAIL_BAN_SECONDS = 300

_auth_fail_history: dict[str, list[float]] = {}
_auth_ban_until: dict[str, float] = {}

# --- Cross-tenant impersonation guard --------------------------------------

# Zone under which every tenant subdomain lives (e.g. "pvh-labs.com" today,
# "be-bop.shop" tomorrow — same variable). Sourced from the same env var
# the rest of the tooling uses.
ZONE = os.environ.get("OVH_DNS_ZONE", "").strip().lower()

# --- Zulip notifications ---------------------------------------------------

ZULIP_SITE = os.environ.get("ZULIP_SITE", "").strip().rstrip("/")
ZULIP_BOT_EMAIL = os.environ.get("ZULIP_BOT_EMAIL", "").strip()
ZULIP_BOT_API_KEY = os.environ.get("ZULIP_BOT_API_KEY", "").strip()
ZULIP_STREAM = os.environ.get("ZULIP_STREAM", "").strip()
ZULIP_TOPIC = os.environ.get("ZULIP_TOPIC", "mail-relay").strip()
ZULIP_CONFIGURED = bool(ZULIP_SITE and ZULIP_BOT_EMAIL and ZULIP_BOT_API_KEY and ZULIP_STREAM)


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


def _peer_key(session) -> str:
    """Extract the source address for auth-failure accounting. We use the
    IP only (not port) so a bad actor rotating source ports still hits
    the same bucket."""
    peer = getattr(session, "peer", None)
    if not peer:
        return "unknown"
    if isinstance(peer, tuple) and peer:
        return str(peer[0])
    return str(peer)


def _is_auth_banned(peer_key: str) -> bool:
    """Purge expired bans, return True if peer is currently banned."""
    now = time.time()
    ban_until = _auth_ban_until.get(peer_key)
    if ban_until is None:
        return False
    if ban_until <= now:
        _auth_ban_until.pop(peer_key, None)
        return False
    return True


def _record_auth_failure(peer_key: str) -> None:
    """Append a failed-attempt timestamp; ban if threshold crossed within
    the window. In-memory only — a daemon restart clears counters."""
    now = time.time()
    cutoff = now - AUTH_FAIL_WINDOW_SECONDS
    history = _auth_fail_history.setdefault(peer_key, [])
    history[:] = [t for t in history if t >= cutoff]
    history.append(now)
    if len(history) >= AUTH_FAIL_THRESHOLD:
        _auth_ban_until[peer_key] = now + AUTH_FAIL_BAN_SECONDS
        LOG.warning(
            "auth: %s banned for %ds after %d failures in %ds",
            peer_key, AUTH_FAIL_BAN_SECONDS,
            len(history), AUTH_FAIL_WINDOW_SECONDS,
        )
        history.clear()


def _record_auth_success(peer_key: str) -> None:
    """Successful login clears the failure history for that peer — a
    momentary typo shouldn't dig anyone toward a ban."""
    _auth_fail_history.pop(peer_key, None)


def auth_check(server, session, envelope, mechanism, auth_data) -> AuthResult:
    """Called by aiosmtpd for LOGIN and PLAIN. Both mechanisms provide the
    credentials as a LoginPassword named tuple (login, password bytes)."""
    peer_key = _peer_key(session)
    if _is_auth_banned(peer_key):
        LOG.info("auth: rejected (banned) from %s", peer_key)
        return AuthResult(success=False, handled=True)
    if not isinstance(auth_data, LoginPassword):
        LOG.warning("auth: unsupported auth data type %r", type(auth_data))
        _record_auth_failure(peer_key)
        return AuthResult(success=False, handled=True)
    tenant_id = auth_data.login.decode("utf-8", errors="replace").strip()
    if not tenant_id:
        _record_auth_failure(peer_key)
        return AuthResult(success=False, handled=True)
    stored_hash = _lookup_tenant_pass_hash(tenant_id)
    if stored_hash is None:
        LOG.info("auth: unknown or inactive tenant %r from %s", tenant_id, peer_key)
        # Constant-time-ish: still run one bcrypt to smooth out timing.
        bcrypt.checkpw(auth_data.password, bcrypt.hashpw(b"x", bcrypt.gensalt(4)))
        _record_auth_failure(peer_key)
        return AuthResult(success=False, handled=True)
    if not bcrypt.checkpw(auth_data.password, stored_hash):
        LOG.info("auth: bad password for tenant %r from %s", tenant_id, peer_key)
        _record_auth_failure(peer_key)
        return AuthResult(success=False, handled=True)
    LOG.info("auth: tenant %r authenticated from %s", tenant_id, peer_key)
    _record_auth_success(peer_key)
    return AuthResult(success=True, handled=True, auth_data=tenant_id)


# --- Cross-tenant guard ----------------------------------------------------

def check_from_ownership(authed_tenant: str, from_addr: str) -> bool:
    """Enforce that the MAIL FROM address belongs to the tenant that
    authenticated. We locked in subdomain-per-tenant (pattern 2), so the
    From MUST be `*@<tenant>.<ZONE>`. Any other shape gets rejected.
    Skipping the check when ZONE isn't set (dev only) so operators can
    run the relay without secrets.env in a local sandbox."""
    if not ZONE:
        return True
    if not from_addr:
        return False
    try:
        _, domain = from_addr.rsplit("@", 1)
    except ValueError:
        return False
    return domain.strip().lower() == f"{authed_tenant.lower()}.{ZONE}"


# --- Quota bookkeeping -----------------------------------------------------

def _load_tenant_row(tenant_id: str) -> sqlite3.Row | None:
    with db_conn() as conn:
        return conn.execute(
            "SELECT * FROM tenants WHERE tenant_id = ?", (tenant_id,)
        ).fetchone()


def get_window_counters(tenant_id: str) -> dict[str, int]:
    """Return {'10min': n, '24h': n, 'month': n} — number of accepted
    sends (status includes 'sent-upstream' and log-only) in each window."""
    counts: dict[str, int] = {}
    with db_conn() as conn:
        for name, offset, *_ in WINDOW_DEFS:
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM send_log "
                "WHERE tenant_id = ? "
                "  AND status IN ('sent-upstream', 'log-only') "
                "  AND sent_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?)",
                (tenant_id, offset),
            ).fetchone()
            counts[name] = row["n"] if row else 0
    return counts


def effective_thresholds(row: sqlite3.Row | None) -> dict[str, tuple[int, int]]:
    """Merge per-tenant overrides with daemon defaults. Returns
    {window: (hard, soft)}."""
    out: dict[str, tuple[int, int]] = {}
    for name, _off, def_hard, def_soft, _cd, hard_col, soft_col in WINDOW_DEFS:
        hard = row[hard_col] if row and row[hard_col] is not None else def_hard
        soft = row[soft_col] if row and row[soft_col] is not None else def_soft
        out[name] = (hard, soft)
    return out


def find_first_hard_breach(counts: dict[str, int],
                            caps: dict[str, tuple[int, int]]) -> str | None:
    """Return the window name whose count is AT OR ABOVE its hard cap, or
    None. We block if the CURRENT count (before this send) already sits at
    the cap: allowing "one over" would let 5% of tenants slip past."""
    for name in caps:
        current = counts.get(name, 0)
        hard, _soft = caps[name]
        if current >= hard:
            return name
    return None


def find_new_soft_breaches(counts_before: dict[str, int],
                            counts_after: dict[str, int],
                            caps: dict[str, tuple[int, int]]) -> list[str]:
    """Return windows where the soft alert was JUST crossed by this
    send (before < soft <= after). Windows already above soft on prior
    sends aren't returned here; the cool-down layer handles those."""
    breached = []
    for name in caps:
        _hard, soft = caps[name]
        if counts_before.get(name, 0) < soft <= counts_after.get(name, 0):
            breached.append(name)
    return breached


# --- Zulip alerts + cool-down ---------------------------------------------

def _send_zulip(subject: str, body: str) -> None:
    """Best-effort POST to Zulip's send-message API. Failures are logged
    only — we never let an alert failure block a send that just went
    through (or vice versa)."""
    if not ZULIP_CONFIGURED:
        LOG.info("zulip not configured; would have sent: %s", subject)
        return
    try:
        data = urllib.parse.urlencode({
            "type": "stream",
            "to": ZULIP_STREAM,
            "topic": ZULIP_TOPIC,
            "content": f"**{subject}**\n{body}",
        }).encode("utf-8")
        auth = base64.b64encode(
            f"{ZULIP_BOT_EMAIL}:{ZULIP_BOT_API_KEY}".encode("utf-8")
        ).decode("ascii")
        req = urllib.request.Request(
            f"{ZULIP_SITE}/api/v1/messages",
            data=data,
            headers={
                "Authorization": f"Basic {auth}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status >= 400:
                LOG.warning("zulip: HTTP %s on send", resp.status)
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        LOG.warning("zulip send failed: %s", exc)


def _cooldown_for(window: str) -> int:
    for name, _off, _dh, _ds, cd, *_ in WINDOW_DEFS:
        if name == window:
            return cd
    return COOLDOWN_10MIN_SECONDS


def _maybe_alert_soft(tenant_id: str, window: str,
                       current_count: int, hard: int, soft: int) -> None:
    """Fire a Zulip soft-alert notif if this (tenant, window) hasn't been
    alerted within its cool-down. Uses alert_state as source of truth so
    a daemon restart doesn't re-flood."""
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    cutoff_delta = _cooldown_for(window)
    with db_conn() as conn:
        row = conn.execute(
            "SELECT last_alert_at FROM alert_state "
            "WHERE tenant_id = ? AND window_kind = ?",
            (tenant_id, window),
        ).fetchone()
        if row and row["last_alert_at"]:
            try:
                last = datetime.strptime(row["last_alert_at"], "%Y-%m-%dT%H:%M:%SZ")
                last = last.replace(tzinfo=timezone.utc)
                if (datetime.now(timezone.utc) - last).total_seconds() < cutoff_delta:
                    return
            except ValueError:
                pass  # malformed timestamp — treat as no prior alert
        conn.execute(
            "INSERT INTO alert_state (tenant_id, window_kind, last_alert_at) "
            "VALUES (?, ?, ?) "
            "ON CONFLICT(tenant_id, window_kind) DO UPDATE SET last_alert_at = excluded.last_alert_at",
            (tenant_id, window, now_iso),
        )
    site_url = f"https://{tenant_id}.{ZONE}/" if ZONE else f"(tenant {tenant_id})"
    subject = f"[be-BOP mail-relay] soft alert {window} — tenant '{tenant_id}'"
    body = (
        f"Tenant `{tenant_id}` a franchi le soft alert de la fenêtre `{window}` "
        f"(compte actuel : {current_count} / soft {soft}, hard {hard}).\n"
        f"Site : {site_url}"
    )
    _send_zulip(subject, body)


def _alert_hard_cap(tenant_id: str, window: str, current_count: int, hard: int) -> None:
    """Fire a Zulip alert once when the hard cap kicks in. Uses a distinct
    marker so we don't collide with soft-alert cool-downs."""
    marker = f"{window}:hard"
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with db_conn() as conn:
        row = conn.execute(
            "SELECT last_alert_at FROM alert_state "
            "WHERE tenant_id = ? AND window_kind = ?",
            (tenant_id, marker),
        ).fetchone()
        if row and row["last_alert_at"]:
            try:
                last = datetime.strptime(row["last_alert_at"], "%Y-%m-%dT%H:%M:%SZ")
                last = last.replace(tzinfo=timezone.utc)
                # Re-alert on hard cap at most once per hour — enough to
                # keep ops looking without being noisy.
                if (datetime.now(timezone.utc) - last).total_seconds() < 3600:
                    return
            except ValueError:
                pass
        conn.execute(
            "INSERT INTO alert_state (tenant_id, window_kind, last_alert_at) "
            "VALUES (?, ?, ?) "
            "ON CONFLICT(tenant_id, window_kind) DO UPDATE SET last_alert_at = excluded.last_alert_at",
            (tenant_id, marker, now_iso),
        )
    site_url = f"https://{tenant_id}.{ZONE}/" if ZONE else f"(tenant {tenant_id})"
    subject = f"[be-BOP mail-relay] HARD CAP {window} — tenant '{tenant_id}'"
    body = (
        f"Tenant `{tenant_id}` a atteint le HARD CAP de la fenêtre `{window}` "
        f"(compte : {current_count} / hard {hard}). Les nouveaux mails sont rejetés en 550. "
        f"Contacter le marchand via l'admin be-BOP de vente pour bascule sur son propre SMTP.\n"
        f"Site : {site_url}"
    )
    _send_zulip(subject, body)


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
        if not check_from_ownership(session.auth_data, address):
            LOG.warning(
                "MAIL FROM rejected: tenant=%s tried to send as %s",
                session.auth_data, address,
            )
            return "550 5.7.1 sender address does not match authenticated tenant"
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

        # 1. Rate-limit / quota check BEFORE forwarding. We snapshot the
        # counters both to reject the message on hard-breach and to detect
        # soft-alert crossings once the send completes.
        row = _load_tenant_row(tenant_id)
        caps = effective_thresholds(row)
        counts_before = get_window_counters(tenant_id)
        breached = find_first_hard_breach(counts_before, caps)
        if breached is not None:
            hard, _ = caps[breached]
            LOG.warning(
                "hard cap breached tenant=%s window=%s count=%d/%d — rejecting",
                tenant_id, breached, counts_before[breached], hard,
            )
            _alert_hard_cap(tenant_id, breached, counts_before[breached], hard)
            self._insert_send_log(
                tenant_id, envelope, size, f"rejected-quota-{breached}",
            )
            return "550 5.7.1 quota exceeded — contact be-BOP support"

        # 2. Forward (or fall back to log-only if provider not configured).
        if not UPSTREAM_CONFIGURED:
            LOG.info(
                "log-only (no upstream) tenant=%s from=%s to=%r size=%d",
                tenant_id, envelope.mail_from, envelope.rcpt_tos, size,
            )
            self._insert_send_log(tenant_id, envelope, size, "log-only")
            self._check_soft_alerts(tenant_id, counts_before, caps)
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
        # Soft alerts trigger only when the send actually landed at
        # upstream. Rejections and 5xx don't add to the accepted count,
        # so they can't move the tenant across the soft threshold.
        if status == "sent-upstream":
            self._check_soft_alerts(tenant_id, counts_before, caps)
        return reply

    def _insert_send_log(self, tenant_id, envelope, size, status):
        with db_conn() as conn:
            for rcpt in envelope.rcpt_tos:
                conn.execute(
                    "INSERT INTO send_log (tenant_id, recipient, size_bytes, status) "
                    "VALUES (?, ?, ?, ?)",
                    (tenant_id, rcpt, size, status),
                )

    def _check_soft_alerts(self, tenant_id, counts_before, caps):
        """Called after a successful accept (log-only or sent-upstream) to
        fire Zulip alerts on newly-crossed soft thresholds. counts_before
        is the pre-send snapshot; counts_after is re-queried here so we
        catch crossings that happen exactly on this send."""
        counts_after = get_window_counters(tenant_id)
        for window in find_new_soft_breaches(counts_before, counts_after, caps):
            hard, soft = caps[window]
            _maybe_alert_soft(tenant_id, window, counts_after[window], hard, soft)


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

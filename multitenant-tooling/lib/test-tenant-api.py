#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
"""
test-tenant-api.py — HTTP daemon that receives a paid-order webhook from
a be-BOP "spawn a test tenant" shop and provisions an ephemeral test tenant
on this host.

Listens on 127.0.0.1:<BEBOP_DEPLOY_API_PORT> (nginx terminates TLS on
deploy.<OVH_DNS_ZONE> and reverse-proxies here). Uses only Python stdlib:
no new package dependency on the host.

Auth model (mirrors be-BOP's outbound webhook signing convention):
  - Header `X-Webhook-Signature: sha256=<hex>`
  - <hex> = HMAC-SHA256(BEBOP_DEPLOY_API_SECRET, raw_body_bytes)
  - Constant-time compare; reject 401 otherwise.

Replay protection:
  - Reject if `abs(now - timestamp)` > BEBOP_DEPLOY_API_REPLAY_WINDOW_SECONDS.
  - `timestamp` is the JSON field at the top of the be-BOP paid-order payload.

Lifecycle of a successful POST /deploy-test-tenant:
  1. Verify signature + freshness.
  2. Extract config from `customCheckoutFields` by slug (TBD — see
     extract_tenant_config below).
  3. Refuse if the host-wide cap or this tenant_id are already used.
  4. Reserve expiry row (status=provisioning).
  5. Fork add-tenant.sh + tenant-cli release install branch=<branch>.
  6. On success: email the buyer (contact.email) the tenant URL via SMTP.
  7. On failure: notify operator via lib/notify.sh and roll back the
     expiry row.

The daemon NEVER touches the be-BOP code directly; everything goes through
add-tenant.sh / remove-tenant.sh / tenant-cli.sh which own all rollback
and side-effect tracking.
"""
from __future__ import annotations

import hashlib
import hmac
import html
import json
import logging
import os
import re
import smtplib
import subprocess
import sys
import threading
import unicodedata
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOG = logging.getLogger("test-tenant-api")

# --- Config (env-driven; populated in main()) -------------------------------
CFG: dict = {}

# HTML template + logo for the buyer notification. Both sit next to the
# script tree at <install-prefix>/templates/. Loaded lazily and cached.
# The logo ships as PNG (rendered from bebop-light.svg) because SVG and
# data URIs are stripped by Gmail/Outlook — only multipart/related + CID
# has broad email-client support.
TEMPLATES_DIR = Path(__file__).resolve().parent.parent / "templates"
TEMPLATE_PATH = TEMPLATES_DIR / "tenant-up-notification.html"
LOGO_PATH = TEMPLATES_DIR / "tenant-up-notification-logo.png"
LOGO_CID = "tenant-up-logo"
_HTML_TEMPLATE_CACHE: str | None = None
_LOGO_BYTES_CACHE: bytes | None = None

# --- Tenant id rules (must match add-tenant.sh) -----------------------------
TENANT_REGEX = re.compile(r"^[a-z0-9][a-z0-9-]*$")
TENANT_MAX_LEN = 32
RESERVED_TENANT_IDS = {
    "netdata", "kuma", "grafana", "monitoring", "metrics", "status",
    "s3", "garage", "www", "admin", "api", "mail", "mx", "ns", "dns",
    "root", "system", "bebop", "phoenixd", "mongod",
    "dashboard", "panel", "saas", "ops", "deploy",
}


# --- Helpers ----------------------------------------------------------------
def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso8601(dt: datetime) -> str:
    """RFC 3339 UTC, second precision (matches add-tenant.sh / registry)."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso8601(s: str) -> datetime:
    """Parse a be-BOP timestamp. Accepts Z or +00:00 suffix, ms optional."""
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


def verify_signature(raw_body: bytes, header_value: str, secret: bytes) -> bool:
    """Constant-time HMAC-SHA256 verify of `sha256=<hex>`."""
    if not header_value.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret, raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header_value)


def is_fresh(timestamp_iso: str, window_seconds: int) -> bool:
    try:
        ts = parse_iso8601(timestamp_iso)
    except ValueError:
        return False
    delta = abs((now_utc() - ts).total_seconds())
    return delta <= window_seconds


# --- Custom-field extraction (TBD) -----------------------------------------
def extract_tenant_config(payload: dict) -> dict:
    """
    Map be-BOP `customCheckoutFields` to the tenant config our daemon needs.

    The slug → field mapping is operator-defined (the be-BOP shop's checkout
    schema). This function returns a dict with keys:
        tenant_id    : required, str
        admin_email  : required, str  (defaults to payload['contact']['email'])
        branch       : optional, str  (defaults to CFG['branch_default'])
        first_name   : optional, str  (from payload['billingAddress']['firstName'];
                                       '' if billingAddress absent)

    Slug mapping (be-BOP shop checkout schema):
        slug == 'subdomain'    → tenant_id (REQUIRED)
        slug == 'admin-email'  → admin_email override (optional;
                                 fallback = payload.contact.email)
        slug == 'branch'       → branch override (optional;
                                 fallback = CFG['branch_default'] == 'main')
    firstName does NOT come from customCheckoutFields — be-BOP collects it
    in the standard billing-address block of the paid-order webhook.
    """
    fields = payload.get("customCheckoutFields") or []
    by_slug: dict[str, str] = {}
    for entry in fields:
        slug = entry.get("slug")
        # `value` for text fields; `address` for address fields (ignored here —
        # no current use, but we tolerate them so unrelated fields don't crash
        # the handler).
        if slug and "value" in entry:
            by_slug[slug] = entry["value"]

    raw_subdomain = (by_slug.get("subdomain") or "").strip()
    if not raw_subdomain:
        raise ValueError("missing customCheckoutField slug='subdomain'")
    tenant_id = normalize_subdomain(raw_subdomain)
    if not tenant_id:
        raise ValueError(
            f"subdomain '{raw_subdomain}' normalised to an empty slug "
            "(only non-ascii / punctuation?)"
        )
    if tenant_id != raw_subdomain.lower():
        LOG.info("subdomain normalised: %r → %r", raw_subdomain, tenant_id)

    # Default admin_email = buyer's contact email; overridable per checkout.
    admin_email = by_slug.get("admin-email", "").strip()
    if not admin_email:
        admin_email = (payload.get("contact") or {}).get("email") or ""
    if not admin_email:
        raise ValueError("missing admin_email (no slug='admin-email' AND no contact.email)")

    branch = (by_slug.get("branch") or CFG["branch_default"]).strip()

    billing = payload.get("billingAddress") or {}
    first_name = (billing.get("firstName") or "").strip()

    return {
        "tenant_id": tenant_id,
        "admin_email": admin_email,
        "branch": branch,
        "first_name": first_name,
    }


def normalize_subdomain(raw: str) -> str:
    """Turn a buyer-supplied free-form string into a valid DNS subdomain slug.

    Operations: Unicode NFKD + ASCII fold (strips accents — `Café` → `Cafe`),
    lowercase, every non-`[a-z0-9]` run collapses to a single `-`, leading/
    trailing hyphens trimmed, then truncated to TENANT_MAX_LEN and any tail
    hyphen the truncation produced is stripped. Empty / all-junk input
    yields an empty string — caller must reject it.
    """
    if not raw:
        return ""
    nfkd = unicodedata.normalize("NFKD", raw)
    ascii_only = nfkd.encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_only.lower()).strip("-")
    return slug[:TENANT_MAX_LEN].rstrip("-")


def validate_tenant_id(tenant_id: str) -> None:
    if not TENANT_REGEX.match(tenant_id):
        raise ValueError(f"invalid tenant_id '{tenant_id}': must match {TENANT_REGEX.pattern}")
    if len(tenant_id) > TENANT_MAX_LEN:
        raise ValueError(f"tenant_id too long (max {TENANT_MAX_LEN}): '{tenant_id}'")
    if tenant_id in RESERVED_TENANT_IDS:
        raise ValueError(f"tenant_id '{tenant_id}' is reserved")


# --- External calls ---------------------------------------------------------
def run(cmd: list[str], timeout: int = 600) -> tuple[int, str, str]:
    """Run cmd, capture stdout/stderr, never raise. Returns (rc, out, err)."""
    LOG.info("exec: %s", " ".join(cmd))
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        return 124, e.stdout or "", e.stderr or f"timeout after {timeout}s"


def add_tenant(tenant_id: str, admin_email: str) -> tuple[int, str, str]:
    return run([
        "add-tenant.sh", tenant_id,
        "--admin-email", admin_email,
        "--non-interactive",
    ], timeout=900)


def install_branch(tenant_id: str, branch: str) -> tuple[int, str, str]:
    return run([
        "tenant-cli.sh", "--tenant", tenant_id,
        "release", "install", f"branch={branch}",
    ], timeout=900)


def remove_tenant(tenant_id: str) -> tuple[int, str, str]:
    return run([
        "remove-tenant.sh", tenant_id,
        "--purge", "--i-know-what-im-doing", "--non-interactive",
    ], timeout=600)


# --- Email ------------------------------------------------------------------
def _load_html_template() -> str | None:
    """Load the HTML template once and cache. Returns None if unreadable
    (send_buyer_email then falls back to text-only)."""
    global _HTML_TEMPLATE_CACHE
    if _HTML_TEMPLATE_CACHE is not None:
        return _HTML_TEMPLATE_CACHE
    try:
        _HTML_TEMPLATE_CACHE = TEMPLATE_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        LOG.error("html template unreadable at %s: %s", TEMPLATE_PATH, exc)
        _HTML_TEMPLATE_CACHE = ""
    return _HTML_TEMPLATE_CACHE or None


def _load_logo_bytes() -> bytes | None:
    """Load the logo PNG once and cache. Returns None if unreadable
    (send_buyer_email then sends HTML with a broken <img cid:> link,
    which is fine — text alternative still lands)."""
    global _LOGO_BYTES_CACHE
    if _LOGO_BYTES_CACHE is not None:
        return _LOGO_BYTES_CACHE
    try:
        _LOGO_BYTES_CACHE = LOGO_PATH.read_bytes()
    except OSError as exc:
        LOG.error("logo PNG unreadable at %s: %s", LOGO_PATH, exc)
        _LOGO_BYTES_CACHE = b""
    return _LOGO_BYTES_CACHE or None


def render_buyer_html(first_name: str, backoffice_url: str) -> str | None:
    """Render the HTML template with buyer data. Placeholders:
        {{firstName}}      → escaped first_name; if empty, the leading
                             ' {{firstName}}' is stripped so the greeting
                             becomes 'Bonjour,' (no dangling space + comma).
        {{backofficeUrl}}  → escaped backoffice URL (used in href AND
                             visible link text).
    """
    tpl = _load_html_template()
    if not tpl:
        return None
    if first_name:
        tpl = tpl.replace("{{firstName}}", html.escape(first_name))
    else:
        tpl = tpl.replace(" {{firstName}}", "")
    return tpl.replace("{{backofficeUrl}}", html.escape(backoffice_url, quote=True))


def send_buyer_email(
    to_addr: str, first_name: str, backoffice_url: str, expires_at: str
) -> None:
    """Send a one-shot mail to the buyer with their test tenant back-office URL."""
    host = CFG.get("smtp_host")
    if not host or not to_addr:
        LOG.warning("send_buyer_email: SMTP_HOST or recipient empty; skipping")
        return
    port = int(CFG.get("smtp_port") or 587)
    user = CFG.get("smtp_user") or ""
    pwd = CFG.get("smtp_password") or ""
    sender = CFG.get("smtp_from") or user or "no-reply@localhost"

    greeting = f"Bonjour {first_name}," if first_name else "Bonjour,"
    text_body = (
        f"{greeting}\n\n"
        f"Votre boutique be-BOP de test est prête. Accédez à votre arrière-boutique :\n"
        f"  {backoffice_url}\n\n"
        f"Elle sera automatiquement supprimée le {expires_at} (UTC).\n\n"
        f"— be-BOP\n"
    )

    msg = EmailMessage()
    msg["Subject"] = "Votre boutique be-BOP est prête"
    msg["From"] = sender
    msg["To"] = to_addr
    msg.set_content(text_body)
    html_body = render_buyer_html(first_name, backoffice_url)
    if html_body:
        msg.add_alternative(html_body, subtype="html")
        # Embed the logo as a related MIME part so Gmail/Outlook display it.
        # data: URIs and SVG-from-URL are stripped by most webmail clients;
        # multipart/related + Content-ID (`cid:LOGO_CID`) is the only method
        # with broad support.
        logo = _load_logo_bytes()
        if logo:
            html_part = msg.get_payload()[-1]
            html_part.add_related(
                logo, maintype="image", subtype="png", cid=LOGO_CID
            )
    else:
        LOG.warning("send_buyer_email: HTML template unavailable, sending text-only")
    try:
        # Port 465 = SMTPS (implicit TLS from the get-go). Anything else
        # (587 default, 25, …) is plain SMTP + STARTTLS upgrade. Using SMTP()
        # on port 465 hangs the handshake → timeout, which is what bit us.
        if port == 465:
            smtp_cls = smtplib.SMTP_SSL
        else:
            smtp_cls = smtplib.SMTP
        with smtp_cls(host, port, timeout=30) as smtp:
            smtp.ehlo()
            if port != 465:
                try:
                    smtp.starttls()
                    smtp.ehlo()
                except smtplib.SMTPException:
                    # Server doesn't advertise STARTTLS — accept (best effort).
                    LOG.warning("send_buyer_email: STARTTLS unavailable on %s:%d", host, port)
            if user:
                smtp.login(user, pwd)
            smtp.send_message(msg)
        LOG.info("send_buyer_email: sent to %s", to_addr)
    except Exception as exc:  # noqa: BLE001 — operator-visible best-effort path
        LOG.error("send_buyer_email: failed (%s)", exc)


def notify_operator_failure(tenant_id: str, reason: str) -> None:
    """Best-effort operator alert via lib/notify.sh wrapper (bash). Failure
    here doesn't matter; the daemon already logs to journald."""
    bash = (
        "set -e; "
        "source /usr/local/share/be-BOP-tooling/lib/log.sh; "
        "source /usr/local/share/be-BOP-tooling/lib/notify.sh; "
        f"notify_failure '[be-BOP tooling] deploy-test-tenant {tenant_id} FAILED' "
        f"{json.dumps(reason)}"
    )
    try:
        subprocess.run(["bash", "-c", bash], timeout=30, check=False)
    except Exception as exc:  # noqa: BLE001
        LOG.error("notify_operator_failure: %s", exc)


# --- HTTP handler -----------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    # Quieter logs: pipe through our LOG.
    def log_message(self, fmt: str, *args) -> None:  # noqa: D401, N802
        LOG.info("%s - " + fmt, self.client_address[0], *args)

    def _send_json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode("utf-8")
        # Log the error reason at WARNING level for any 4xx/5xx so journalctl
        # carries the diagnostic without us having to capture be-BOP's reply
        # body (be-BOP is fire-and-forget; the reply is discarded).
        if code >= 400 and "error" in obj:
            LOG.warning("HTTP %d %s — %s", code, self.path, obj["error"])
        body_len = len(body)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(body_len))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            return self._send_json(200, {"ok": True})
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 — stdlib API
        if self.path != "/deploy-test-tenant":
            return self._send_json(404, {"error": "not found"})

        # Read raw body. Content-Length is required (be-BOP's outbound webhook
        # sends a fixed-size JSON body; we don't accept chunked).
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            return self._send_json(400, {"error": "bad Content-Length"})
        if length <= 0 or length > 1 * 1024 * 1024:  # 1 MiB cap
            return self._send_json(413, {"error": "body too large or empty"})
        raw = self.rfile.read(length)

        # 1. Signature.
        sig_header = self.headers.get("X-Webhook-Signature") or ""
        if not verify_signature(raw, sig_header, CFG["secret"].encode()):
            return self._send_json(401, {"error": "bad signature"})

        # 2. JSON.
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return self._send_json(400, {"error": "bad JSON"})

        # Log the raw payload (post-signature, pre-extraction) so the operator
        # can see exactly what be-BOP sent — useful when slug mappings change
        # or buyer emails go missing. The webhook body has no secret data
        # (HMAC signature is on the header), so logging is safe.
        LOG.info("payload: %s", json.dumps(payload, ensure_ascii=False))

        # 3. Replay window.
        ts = payload.get("timestamp")
        if not isinstance(ts, str) or not is_fresh(ts, CFG["replay_window_seconds"]):
            return self._send_json(401, {"error": "stale or missing timestamp"})

        # 4. Extract tenant config from customCheckoutFields.
        try:
            cfg = extract_tenant_config(payload)
            validate_tenant_id(cfg["tenant_id"])
        except ValueError as exc:
            return self._send_json(400, {"error": str(exc)})

        tenant_id = cfg["tenant_id"]
        admin_email = cfg["admin_email"]
        branch = cfg["branch"]
        first_name = cfg["first_name"]
        buyer_email = (payload.get("contact") or {}).get("email") or ""
        order_number = payload.get("orderNumber")

        # 5. Provision in a background thread so the webhook returns 202 fast.
        # be-BOP does NOT retry on timeout (PoC convention), so we want to
        # ACK before a long add-tenant.sh run starts.
        threading.Thread(
            target=self._provision,
            args=(tenant_id, admin_email, branch, buyer_email, first_name, order_number),
            daemon=True,
            name=f"provision-{tenant_id}",
        ).start()

        return self._send_json(202, {
            "ok": True,
            "tenant_id": tenant_id,
            "expected_url": f"https://{tenant_id}.{CFG['ovh_dns_zone']}/",
            "ttl_seconds": CFG["ttl_seconds"],
        })

    def _provision(
        self,
        tenant_id: str,
        admin_email: str,
        branch: str,
        buyer_email: str,
        first_name: str,
        order_number: object,
    ) -> None:
        zone = CFG["ovh_dns_zone"]
        tenant_url = f"https://{tenant_id}.{zone}/"
        backoffice_url = f"https://{tenant_id}.{zone}/admin"
        expires_at = iso8601(now_utc() + timedelta(seconds=CFG["ttl_seconds"]))

        # Track BEFORE provisioning: if provisioning crashes hard, the reaper
        # will purge any half-created tenant at expires_at (worst case 2h).
        track_rc, _, track_err = run([
            "bash", "-c",
            "source /usr/local/share/be-BOP-tooling/lib/log.sh; "
            "source /usr/local/share/be-BOP-tooling/lib/sudo.sh; "
            "source /usr/local/share/be-BOP-tooling/lib/test-tenant.sh; "
            "test_tenant_expiry_init; test_tenant_expiry_lock; "
            f"test_tenant_expiry_add {tenant_id!r} {expires_at!r}; "
            "test_tenant_expiry_unlock",
        ], timeout=30)
        if track_rc != 0:
            LOG.error("provision %s: expiry-track failed (rc=%d): %s",
                      tenant_id, track_rc, track_err)
            notify_operator_failure(tenant_id, f"expiry-track failed: {track_err}")
            return

        rc, _, err = add_tenant(tenant_id, admin_email)
        if rc != 0:
            LOG.error("provision %s: add-tenant failed (rc=%d): %s", tenant_id, rc, err)
            notify_operator_failure(tenant_id, f"add-tenant failed: {err[:500]}")
            # add-tenant.sh rolls back its own resources; just untrack the row
            # so the reaper doesn't try to remove a non-existent tenant.
            run([
                "bash", "-c",
                "source /usr/local/share/be-BOP-tooling/lib/log.sh; "
                "source /usr/local/share/be-BOP-tooling/lib/sudo.sh; "
                "source /usr/local/share/be-BOP-tooling/lib/test-tenant.sh; "
                "test_tenant_expiry_lock; "
                f"test_tenant_expiry_remove {tenant_id!r}; "
                "test_tenant_expiry_unlock",
            ], timeout=30)
            return

        # Tenant is up on `latest`. Now swap to the branch build.
        rc, _, err = install_branch(tenant_id, branch)
        if rc != 0:
            LOG.error("provision %s: branch install failed (rc=%d): %s",
                      tenant_id, rc, err)
            notify_operator_failure(tenant_id, f"branch install failed: {err[:500]}")
            # Tenant exists but is on the wrong version; leave it for now so the
            # buyer sees something and the reaper still kills it at expiry.
            # We DO email them so they don't think nothing happened.

        # Email buyer with their back-office URL (best-effort; logs on failure).
        send_buyer_email(buyer_email, first_name, backoffice_url, expires_at)
        LOG.info("provision %s: ready at %s (expires %s, order=%s)",
                 tenant_id, tenant_url, expires_at, order_number)


# --- Bootstrap --------------------------------------------------------------
def load_cfg() -> dict:
    """Load config from environment. Required vars:
        BEBOP_DEPLOY_API_SECRET, OVH_DNS_ZONE
    Optional, with defaults:
        BEBOP_DEPLOY_API_BIND_ADDR        (default 127.0.0.1)
        BEBOP_DEPLOY_API_PORT             (default 8820)
        BEBOP_DEPLOY_API_REPLAY_WINDOW_SECONDS (default 300)
        BEBOP_TEST_TENANT_TTL_SECONDS     (default 7200)
        BEBOP_TEST_TENANT_BRANCH          (default 'main')
        SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM (for buyer mail)
    """
    secret = os.environ.get("BEBOP_DEPLOY_API_SECRET") or ""
    if not secret:
        sys.exit("BEBOP_DEPLOY_API_SECRET is empty — refusing to start")
    zone = os.environ.get("OVH_DNS_ZONE") or ""
    if not zone:
        sys.exit("OVH_DNS_ZONE is empty — refusing to start")
    return {
        "secret": secret,
        "ovh_dns_zone": zone,
        "bind_addr": os.environ.get("BEBOP_DEPLOY_API_BIND_ADDR", "127.0.0.1"),
        "port": int(os.environ.get("BEBOP_DEPLOY_API_PORT", "8820")),
        "replay_window_seconds": int(
            os.environ.get("BEBOP_DEPLOY_API_REPLAY_WINDOW_SECONDS", "300")),
        "ttl_seconds": int(os.environ.get("BEBOP_TEST_TENANT_TTL_SECONDS", "7200")),
        "branch_default": os.environ.get("BEBOP_TEST_TENANT_BRANCH", "main"),
        "smtp_host": os.environ.get("SMTP_HOST", ""),
        "smtp_port": os.environ.get("SMTP_PORT", "587"),
        "smtp_user": os.environ.get("SMTP_USER", ""),
        "smtp_password": os.environ.get("SMTP_PASSWORD", ""),
        "smtp_from": os.environ.get("SMTP_FROM", ""),
    }


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("BEBOP_DEPLOY_API_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    CFG.update(load_cfg())
    server = ThreadingHTTPServer((CFG["bind_addr"], CFG["port"]), Handler)
    LOG.info("deploy API listening on %s:%d (zone=%s, ttl=%ds, replay-window=%ds)",
             CFG["bind_addr"], CFG["port"], CFG["ovh_dns_zone"],
             CFG["ttl_seconds"], CFG["replay_window_seconds"])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutting down on SIGINT")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

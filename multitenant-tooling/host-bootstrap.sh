#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# host-bootstrap.sh — provision a Debian 12 VDS to host multiple isolated
# be-BOP tenants.
#
# Run ONCE on a fresh host as root (or with passwordless sudo). The script is
# idempotent: re-running is safe and only fixes what is missing or has drifted.
#
# What this script DOES NOT do:
#   - Create any tenant. (See add-tenant.sh.)
#   - Issue any TLS certificate. (Per-tenant SAN certs are issued by add-tenant.sh
#     via DNS-01 through the configured DNS provider; the only cert-related
#     thing here is verifying the provider credentials work.)
#   - Start any mongod. The default mongod.service shipped by mongodb-org is
#     masked; per-tenant mongod@<tenant>.service instances are started by
#     add-tenant.sh.
#
# What this script DOES, in order:
#   1.  Validates the host (Debian 12, RAM, disk, AVX support).
#   2.  Loads /etc/be-BOP-tooling/secrets.env.
#   3.  Verifies DNS provider API credentials work (dns_provider_ping).
#   4.  Installs apt packages: nodejs, pnpm, mongodb-org + mongodb-mongosh +
#       mongodb-database-tools, certbot, nginx, docker, netdata, plus
#       the build/runtime deps (curl, jq, stow, openssl, unzip, python3-venv).
#       certbot's DNS-01 challenge is handled by our hooks/certbot-dns-{auth,
#       cleanup}.sh scripts talking to lib/dns_provider.sh, so no
#       certbot-dns-<provider> plugin is required.
#   5.  Downloads & stows Garage and phoenixd binaries.
#   6.  Creates the /var/lib/be-BOP/, /etc/be-BOP/, /etc/be-BOP-tooling/,
#       /etc/phoenixd/, /etc/be-BOP-mongodb/, /var/lib/be-BOP-mongodb/ skeleton.
#   7.  Creates the be-bop-cli system user (parity with v1 wizard, used by
#       upgrade-tenant.sh for systemctl restart privileges).
#   8.  Masks the default mongod.service (we use per-tenant template instances).
#   9.  Writes /etc/garage.toml + garage.service, starts Garage, applies layout.
#  10.  Writes a 444 catch-all default vhost for nginx, then enables nginx.
#  11.  (Legacy cleanup: removes the /etc/letsencrypt/ovh.ini file left
#       behind by hosts that previously used certbot-dns-ovh, since our
#       certbot --manual hooks now read DNS-provider creds directly from
#       secrets.env via lib/dns_provider.sh.)
#  12.  Installs systemd template units bebop@, phoenixd@, mongod@.
#  13.  Installs tooling libs (/usr/local/share/be-BOP-tooling/lib/) and the
#       per-tenant scripts ({add,remove,upgrade}-tenant.sh, upgrade-all.sh).
#  14.  Initialises the empty /var/lib/be-BOP/tenants.tsv registry.
#  15.  Installs Uptime Kuma (Docker, bound to 127.0.0.1:8810) and Netdata.
#  16.  Prints a summary including the next operator step (Uptime Kuma admin
#       account creation, see README).

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="host-bootstrap"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate libs and templates: source-tree layout when invoked from a checkout,
# system layout once installed under /usr/local/share/be-BOP-tooling.
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
    BEBOP_TOOLING_TEMPLATE_DIR="$SCRIPT_DIR/templates"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
    BEBOP_TOOLING_TEMPLATE_DIR=/usr/local/share/be-BOP-tooling/templates
else
    echo "host-bootstrap: cannot locate lib/ directory" >&2
    exit 1
fi
readonly BEBOP_TOOLING_LIB_DIR BEBOP_TOOLING_TEMPLATE_DIR

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"
# shellcheck source=lib/dns_provider.sh
source "$BEBOP_TOOLING_LIB_DIR/dns_provider.sh"
# shellcheck source=lib/nginx.sh
source "$BEBOP_TOOLING_LIB_DIR/nginx.sh"

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# === Constants (overridable via environment) ===========================
: "${NODEJS_MAJOR_VERSION:=20}"
: "${GARAGE_VERSION:=2.2.0}"
: "${PHOENIXD_VERSION:=0.6.2}"
: "${MONGODB_VERSION:=8.0}"
: "${UPTIME_KUMA_IMAGE:=louislam/uptime-kuma:1}"
: "${UPTIME_KUMA_HOST_PORT:=8810}"
: "${BEBOP_TOOLING_INSTALL_PREFIX:=/usr/local/share/be-BOP-tooling}"

# === CLI flags =========================================================
SECRETS_FILE=/etc/be-BOP-tooling/secrets.env
DRY_RUN=false
RUN_NON_INTERACTIVE=false
VERBOSE=false
DEFER_SECRETS=false

usage() {
    cat <<EOF
host-bootstrap.sh — set up shared infra for be-BOP multi-tenant tooling.
Run once on a fresh Debian 12 host. Idempotent.

Usage:
  host-bootstrap.sh [options]

Options:
  --secrets-file <path>  Path to secrets.env. Default: ${SECRETS_FILE}
  --defer-secrets        Run only the steps that do not need secrets.env
                         (apt packages, binaries, dirs, garage, nginx,
                         systemd units, registry, docker, kuma, netdata).
                         Skips DNS-provider connectivity check. Re-run
                         host-bootstrap.sh after editing secrets.env to
                         finalise — it is idempotent.
  --non-interactive      Refuse to prompt; exit if input would be required.
  --dry-run              Print what would happen without changing the system.
  --verbose              Verbose logging (also enables --debug at journald).
  -h, --help             Show this help.

Required environment in secrets.env:
  DNS_PROVIDER (ovh|infomaniak), BEBOP_DNS_ZONE, plus provider-specific
  credentials (OVH_* or INFOMANIAK_*). SFTP/SMTP/Zulip/Kuma are optional.
See templates/secrets.env.example.
EOF
}

while (( $# )); do
    case "$1" in
        --secrets-file)    SECRETS_FILE="$2"; shift 2 ;;
        --defer-secrets)   DEFER_SECRETS=true; shift ;;
        --non-interactive) RUN_NON_INTERACTIVE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --verbose)         VERBOSE=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

export RUN_NON_INTERACTIVE VERBOSE DRY_RUN DEFER_SECRETS

# Wrapper: do nothing in --dry-run mode but still log.
maybe_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run: $*"
    else
        "$@"
    fi
}

# === Prerequisites check ===============================================
step_check_prerequisites() {
    log_info "Checking host prerequisites..."

    # OS detection
    local os_id="" os_codename=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        os_id="${ID:-}"
        os_codename="${VERSION_CODENAME:-}"
    fi
    if [[ "$os_id" != "debian" || "$os_codename" != "bookworm" ]]; then
        die "this script targets Debian 12 (bookworm); detected ID=${os_id} CODENAME=${os_codename}"
    fi
    log_info "OS: Debian 12 (bookworm) ✓"

    # RAM
    local ram_kb
    ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    if (( ram_kb < 2000000 )); then
        log_warn "low RAM: ${ram_kb} kB (recommended: ≥ 2 GiB)"
    fi

    # Disk: free space on /var
    local var_free_gb
    var_free_gb=$(df --output=avail -BG /var | tail -1 | tr -d 'G ')
    if (( var_free_gb < 20 )); then
        log_warn "low free disk on /var: ${var_free_gb}G (recommended: ≥ 20G for releases + Garage)"
    fi

    # systemd
    if ! command -v systemctl >/dev/null 2>&1; then
        die "systemctl not found — host must run systemd"
    fi
    log_info "systemd: present ✓"

    # MongoDB 5.0+ requires AVX on amd64. ARM64 is fine without.
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    if [[ "$arch" == "amd64" || "$arch" == "x86_64" ]]; then
        if ! grep -qE '^flags[[:space:]]*:.* avx( |$)' /proc/cpuinfo; then
            die "MongoDB ${MONGODB_VERSION} requires CPU AVX support; this host's CPU does not advertise it (check /proc/cpuinfo)"
        fi
        log_info "CPU AVX: supported ✓"
    fi
}

# === Secrets ============================================================
step_load_secrets() {
    log_info "Loading secrets from ${SECRETS_FILE}..."
    if [[ ! -f "$SECRETS_FILE" ]]; then
        if [[ "$DEFER_SECRETS" == "true" ]]; then
            log_warn "secrets file not found: ${SECRETS_FILE} — continuing in --defer-secrets mode"
            return 0
        fi
        die "secrets file not found: ${SECRETS_FILE} (copy templates/secrets.env.example, fill it, chmod 600, and rerun)"
    fi
    local mode
    mode=$(stat -c '%a' "$SECRETS_FILE")
    if [[ "$mode" != "600" ]]; then
        log_warn "${SECRETS_FILE} mode is ${mode}; should be 600 (chmod 600 ${SECRETS_FILE})"
    fi
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"

    local missing=()
    local required_vars=(BEBOP_DNS_ZONE)
    # Empty DNS_PROVIDER falls back to "ovh" (matches lib/dns_provider.sh's
    # default), so pre-existing secrets.env files from before the multi-
    # provider refactor keep working without a mandatory edit.
    case "${DNS_PROVIDER:-ovh}" in
        ovh)        required_vars+=(OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY) ;;
        infomaniak) required_vars+=(INFOMANIAK_API_TOKEN) ;;
        *)          die "secrets.env: unknown DNS_PROVIDER='${DNS_PROVIDER}' (want: ovh|infomaniak)" ;;
    esac
    for v in "${required_vars[@]}"; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if (( ${#missing[@]} )); then
        if [[ "$DEFER_SECRETS" == "true" ]]; then
            log_warn "secrets.env has empty values: ${missing[*]} — continuing in --defer-secrets mode"
            return 0
        fi
        die "secrets.env is missing required values: ${missing[*]}"
    fi
    log_info "secrets loaded ✓"
}

# === DNS provider connectivity ==========================================
step_verify_dns_provider_connectivity() {
    if [[ "$DEFER_SECRETS" == "true" ]] && ! dns_provider_is_configured; then
        log_info "Skipping DNS provider connectivity check (--defer-secrets, incomplete creds)"
        return 0
    fi
    log_info "Verifying DNS provider API connectivity (DNS_PROVIDER=${DNS_PROVIDER})..."
    if ! dns_provider_ping; then
        die "DNS provider ping failed; check ${DNS_PROVIDER^^}_* creds in ${SECRETS_FILE}"
    fi
}

# === apt packages =======================================================
step_install_apt_packages() {
    log_info "Updating apt cache and installing core packages..."
    maybe_run run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    local pkgs=(
        ca-certificates curl gpg jq openssl unzip zip stow xxd
        util-linux
        dnsutils                # provides `dig`, used by lib/dns.sh for pre-flight DNS checks
        rclone
        nginx apache2-utils
        certbot
        python3-venv python3-pip
        python3-aiosmtpd        # ingress SMTP (accept from tenants)
        python3-aiosmtplib      # egress SMTP (forward to Scaleway TEM)
        python3-bcrypt          # tenant password hashing for the mail-relay
        python3-pymongo         # mail-relay reads/writes its state in mongod@tooling
        docker.io
        netdata
    )
    maybe_run run_privileged env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "${pkgs[@]}"
}

# === MongoDB APT repo + install =========================================
step_install_mongodb() {
    local list_file="/etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list"
    local keyring="/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg"
    if [[ -f "$list_file" && -f "$keyring" ]]; then
        log_info "MongoDB ${MONGODB_VERSION} apt repo already configured ✓"
    else
        log_info "Configuring MongoDB ${MONGODB_VERSION} apt repository..."
        local arch
        arch=$(dpkg --print-architecture)
        local os_codename=""
        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            os_codename="${VERSION_CODENAME:-bookworm}"
        fi
        # MongoDB publishes per-arch repos (amd64, arm64). Debian 12 (bookworm)
        # uses the corresponding component path under repo.mongodb.org.
        maybe_run run_privileged bash -c "
            curl -fsSL https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc \
                | gpg --batch --yes --dearmor -o '${keyring}' &&
            echo 'deb [arch=${arch} signed-by=${keyring}] https://repo.mongodb.org/apt/debian ${os_codename}/mongodb-org/${MONGODB_VERSION} main' \
                > '${list_file}'
        "
        maybe_run run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    fi
    log_info "Installing mongodb-org + mongodb-mongosh + mongodb-database-tools..."
    maybe_run run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        mongodb-org mongodb-mongosh mongodb-database-tools

    # Mask the default mongod.service that ships with mongodb-org. We use
    # per-tenant mongod@<tenant>.service instances instead. Masking is
    # idempotent and survives package upgrades.
    if systemctl list-unit-files mongod.service --no-legend 2>/dev/null | grep -q .; then
        if ! systemctl is-enabled mongod.service 2>/dev/null | grep -qx 'masked'; then
            log_info "Masking default mongod.service (per-tenant template instances are used instead)..."
            maybe_run run_privileged systemctl disable --now mongod.service 2>/dev/null || true
            maybe_run run_privileged systemctl mask mongod.service
        else
            log_info "default mongod.service already masked ✓"
        fi
    fi
}

# === Node.js + pnpm =====================================================
step_install_nodejs_pnpm() {
    if command -v node >/dev/null 2>&1; then
        local actual
        actual=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)
        if [[ "$actual" == "$NODEJS_MAJOR_VERSION" ]]; then
            log_info "Node.js v${actual} already installed ✓"
        else
            log_warn "Node.js v${actual} installed; expected v${NODEJS_MAJOR_VERSION}"
        fi
    else
        log_info "Configuring NodeSource repository for Node.js ${NODEJS_MAJOR_VERSION}.x..."
        local keyring=/usr/share/keyrings/nodesource.gpg
        maybe_run run_privileged bash -c "
            curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
            gpg --dearmor -o '${keyring}' &&
            echo 'deb [signed-by=${keyring}] https://deb.nodesource.com/node_${NODEJS_MAJOR_VERSION}.x nodistro main' \
                > /etc/apt/sources.list.d/nodesource.list
        "
        maybe_run run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        maybe_run run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi
    if ! command -v corepack >/dev/null 2>&1; then
        die "corepack not available — Node.js install seems broken"
    fi
    log_info "Enabling corepack and pnpm..."
    maybe_run run_privileged corepack enable
    maybe_run run_privileged corepack prepare pnpm@latest --activate
}

# === Garage binary ======================================================
step_install_garage_binary() {
    local stow_dir="/usr/local/garage"
    local pkg_dir="${stow_dir}/garage-v${GARAGE_VERSION}"
    if [[ -x "${pkg_dir}/bin/garage" ]]; then
        log_info "Garage v${GARAGE_VERSION} already installed (${pkg_dir}) ✓"
    else
        log_info "Downloading Garage v${GARAGE_VERSION}..."
        local arch
        case "$(uname -m)" in
            x86_64)  arch="x86_64-unknown-linux-musl" ;;
            aarch64) arch="aarch64-unknown-linux-musl" ;;
            *) die "unsupported CPU architecture: $(uname -m)" ;;
        esac
        local url="https://garagehq.deuxfleurs.fr/_releases/v${GARAGE_VERSION}/${arch}/garage"
        local tmp
        tmp=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf '${tmp}'" RETURN
        maybe_run curl -fsSL --connect-timeout 10 --max-time 300 -o "${tmp}/garage" "${url}"
        maybe_run run_privileged install -d -m 0755 "${pkg_dir}/bin"
        maybe_run run_privileged install -m 0755 "${tmp}/garage" "${pkg_dir}/bin/garage"
        rm -rf "${tmp}"
        trap - RETURN
    fi
    log_info "Stowing Garage..."
    ( cd "${stow_dir}" && maybe_run run_privileged stow --restow "garage-v${GARAGE_VERSION}" )
}

# === phoenixd binary ====================================================
step_install_phoenixd_binary() {
    local stow_dir="/usr/local/phoenixd"
    local pkg_dir="${stow_dir}/phoenixd-${PHOENIXD_VERSION}"
    if [[ -x "${pkg_dir}/bin/phoenixd" ]]; then
        log_info "phoenixd ${PHOENIXD_VERSION} already installed (${pkg_dir}) ✓"
    else
        log_info "Downloading phoenixd ${PHOENIXD_VERSION}..."
        local arch
        case "$(uname -m)" in
            x86_64)  arch="x64" ;;
            aarch64) arch="arm64" ;;
            *) die "unsupported CPU architecture: $(uname -m)" ;;
        esac
        local url="https://github.com/ACINQ/phoenixd/releases/download/v${PHOENIXD_VERSION}/phoenixd-${PHOENIXD_VERSION}-linux-${arch}.zip"
        local tmp
        tmp=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf '${tmp}'" RETURN
        maybe_run curl -fsSL --connect-timeout 10 --max-time 300 -o "${tmp}/phoenixd.zip" "${url}"
        ( cd "${tmp}" && maybe_run unzip -q phoenixd.zip )
        maybe_run run_privileged install -d -m 0755 "${pkg_dir}/bin"
        maybe_run run_privileged bash -c "install -m 0755 ${tmp}/phoenixd-*/phoenixd ${pkg_dir}/bin/"
        maybe_run run_privileged bash -c "install -m 0755 ${tmp}/phoenixd-*/phoenix-cli ${pkg_dir}/bin/"
        rm -rf "${tmp}"
        trap - RETURN
    fi
    log_info "Stowing phoenixd..."
    ( cd "${stow_dir}" && maybe_run run_privileged stow --restow "phoenixd-${PHOENIXD_VERSION}" )
}

# === Filesystem skeleton ================================================
step_setup_directories() {
    log_info "Creating directory skeleton..."
    maybe_run run_privileged install -d -m 0755 /var/lib/be-BOP
    maybe_run run_privileged install -d -m 0755 /etc/be-BOP
    maybe_run run_privileged install -d -m 0700 /etc/be-BOP-tooling
    maybe_run run_privileged install -d -m 0755 /etc/phoenixd
    maybe_run run_privileged install -d -m 0755 /var/lib/phoenixd
    # Per-tenant mongod parents (StateDirectory in mongod@.service creates the
    # per-instance subdirs; we just ensure the parents exist for consistency).
    maybe_run run_privileged install -d -m 0755 /etc/be-BOP-mongodb
    maybe_run run_privileged install -d -m 0755 /var/lib/be-BOP-mongodb
    # Garage state & config dirs (Garage service handles its own state via
    # StateDirectory, but we create the meta/data parents explicitly).
    maybe_run run_privileged install -d -m 0755 /var/lib/garage
    # Let's Encrypt
    maybe_run run_privileged install -d -m 0755 /etc/letsencrypt
}

# === be-bop-cli system user (parity with v1 wizard) =====================
step_setup_user_be_bop_cli() {
    if id be-bop-cli >/dev/null 2>&1; then
        log_info "system user 'be-bop-cli' already exists ✓"
    else
        log_info "Creating system user 'be-bop-cli'..."
        maybe_run run_privileged useradd \
            --system --shell /usr/sbin/nologin \
            --home-dir /var/lib/be-BOP --no-create-home \
            be-bop-cli
    fi
}

# === Garage configuration ===============================================
step_write_garage_config() {
    log_info "Writing /etc/garage.toml..."
    if [[ -f /etc/garage.toml ]]; then
        log_info "/etc/garage.toml already exists; leaving rpc_secret intact"
        return 0
    fi
    local rpc_secret
    rpc_secret=$(openssl rand -hex 32)
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# /etc/garage.toml — managed by be-BOP multi-tenant tooling
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "lmdb"
replication_factor = 1

rpc_secret = "${rpc_secret}"
rpc_bind_addr = "127.0.0.1:3901"

[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3900"
# No root_domain: per-tenant subdomains use path-style (forcePathStyle in
# be-BOP's S3 client). Garage doesn't need to parse the bucket from the host.

[admin]
api_bind_addr = "127.0.0.1:3903"
EOF
    maybe_run run_privileged install -m 0640 "$tmp" /etc/garage.toml
    rm -f "$tmp"
}

step_write_garage_service() {
    log_info "Writing /etc/systemd/system/garage.service..."
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
[Unit]
Description=Garage S3-compatible Storage Server
Documentation=https://garagehq.deuxfleurs.fr
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/garage server
Restart=always
RestartSec=5
TimeoutStartSec=60
TimeoutStopSec=30
StateDirectory=garage
StateDirectoryMode=0755
WorkingDirectory=/var/lib/garage
Environment=HOME=/var/lib/garage
Environment=GARAGE_CONFIG_FILE=/etc/garage.toml
StandardOutput=journal
StandardError=journal
SyslogIdentifier=garage
LimitNOFILE=65536

# Hardening (DynamicUser is NOT used — Garage reads /etc/garage.toml which is
# root:root 0640 to protect rpc_secret).
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictNamespaces=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
    maybe_run run_privileged install -m 0644 "$tmp" /etc/systemd/system/garage.service
    rm -f "$tmp"
    maybe_run run_privileged systemctl daemon-reload
}

step_start_garage() {
    log_info "Enabling and starting garage.service..."
    maybe_run run_privileged systemctl enable --now garage
    log_info "Waiting for Garage to become ready..."
    local retries=10
    while ! run_privileged garage status >/dev/null 2>&1; do
        if (( retries-- <= 0 )); then
            die "Garage did not become ready in 30s"
        fi
        sleep 3
    done
    log_info "Garage ready ✓"
}

step_provision_garage_layout() {
    local node_id
    node_id=$(run_privileged garage node id 2>/dev/null | cut -d'@' -f1)
    if [[ -z "$node_id" ]]; then
        die "could not determine Garage node id"
    fi
    if run_privileged garage status 2>/dev/null | grep "${node_id:0:16}" | grep -q "NO ROLE ASSIGNED"; then
        log_info "Assigning layout to Garage node ${node_id:0:16}..."
        maybe_run run_privileged garage layout assign -z dc1 -c 1G "$node_id"
        local layout_version
        layout_version=$(run_privileged garage layout show 2>/dev/null \
            | awk '/Current cluster layout version:/{print $NF}')
        layout_version=$(( ${layout_version:-0} + 1 ))
        maybe_run run_privileged garage layout apply --version "$layout_version"
    else
        log_info "Garage layout already assigned ✓"
    fi
}

# _nginx_quarantine_broken_vhosts moved to lib/nginx.sh so add-tenant.sh
# can also call it before its own `nginx -t` in phase_nginx. Old callers
# keep working via a compatibility alias inside lib/nginx.sh.

# === nginx default catch-all + ACME HTTP-01 webroot =====================
# The default vhost has TWO responsibilities, both load-bearing:
#   1. Serve the ACME HTTP-01 challenge tokens for ANY hostname on port 80
#      so certbot can issue/renew certs for tenants in external-domain mode
#      (add-tenant.sh --external-domain, B1). All HTTP-01 renewals depend
#      on the /.well-known/acme-challenge/ location being intact — touching
#      it breaks every external-domain tenant's cert renewal silently.
#   2. Drop connections to unknown hosts (return 444) for everything else,
#      so port scans / random Host: headers don't reveal which sites we host.
step_write_nginx_default_vhost() {
    log_info "Writing nginx catch-all + ACME webroot vhost..."
    # Webroot dir certbot writes challenge tokens into. Created world-readable
    # so nginx (running as www-data) can serve them, while certbot (running
    # as root) writes them. The dir itself stays empty between renewals.
    maybe_run run_privileged install -d -m 0755 /var/lib/letsencrypt
    maybe_run run_privileged install -d -m 0755 /var/lib/letsencrypt/.well-known
    maybe_run run_privileged install -d -m 0755 /var/lib/letsencrypt/.well-known/acme-challenge
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
# Catch-all default vhost. Two roles:
#   1. Serve ACME HTTP-01 challenge tokens for ANY hostname (load-bearing —
#      external-domain tenants' cert renewals depend on this location).
#   2. Return 444 for any other request to an unknown host.
# Per-tenant vhosts are added under sites-enabled by add-tenant.sh.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # DO NOT TOUCH: HTTP-01 webroot for certbot. Every external-domain
    # tenant's cert renewal hits this location.
    location ^~ /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt;
        default_type "text/plain";
    }

    location / {
        return 444;
    }
}
EOF
    maybe_run run_privileged install -m 0644 "$tmp" /etc/nginx/sites-available/default
    maybe_run run_privileged ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f "$tmp"
    if [[ "$DRY_RUN" != "true" ]]; then
        _nginx_quarantine_broken_vhosts
        run_privileged nginx -t
        # On a re-run of host-bootstrap (after updating the tooling), nginx
        # is already active and step_start_nginx's `enable --now` is a
        # no-op — without an explicit reload, an updated default vhost
        # template would not take effect until the next reboot. Reload here
        # so the ACME webroot block is live as soon as host-bootstrap
        # finishes.
        if run_privileged systemctl is-active --quiet nginx 2>/dev/null; then
            run_privileged systemctl reload nginx
        fi
    fi
}

# === certbot post-renewal nginx reload hook =============================
# Certbot auto-renews via its daily timer (Debian package). When a cert
# is renewed, nginx must be told to reload — otherwise it keeps serving
# the OLD cert (read at startup) until manual intervention, and the cert
# eventually expires. We install a post-renewal hook so every renewal
# triggers a reload across the entire fleet.
step_install_certbot_nginx_reload_hook() {
    log_info "Installing certbot post-renewal nginx reload hook..."
    maybe_run run_privileged install -d -m 0755 /etc/letsencrypt/renewal-hooks/post
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# be-BOP tooling — reload nginx after any cert renews so the new cert is
# picked up immediately. Installed by host-bootstrap.sh.
exec systemctl reload nginx
EOF
    maybe_run run_privileged install -m 0755 "$tmp" /etc/letsencrypt/renewal-hooks/post/01-reload-nginx.sh
    rm -f "$tmp"
}

# === certbot renewal monitoring =========================================
# Runs `certbot renew --dry-run` weekly and notifies operators (Zulip +
# SMTP) on failure. Active by default for all installs — the cost is
# zero (a few seconds of dry-run per week, no LE quota consumed) and it
# catches silent renewal failures for BOTH DNS-01 (internal tenants) and
# HTTP-01 (external-domain tenants). See B1 in BACKLOG.
step_setup_cert_renewal_monitoring() {
    log_info "Installing bebop-certbot-renew-check.{service,timer}..."
    local u
    for u in bebop-certbot-renew-check.service bebop-certbot-renew-check.timer; do
        maybe_run run_privileged install -m 0644 \
            "${BEBOP_TOOLING_TEMPLATE_DIR}/${u}" "/etc/systemd/system/${u}"
    done
    maybe_run run_privileged systemctl daemon-reload
    maybe_run run_privileged systemctl enable --now bebop-certbot-renew-check.timer
}

step_start_nginx() {
    log_info "Enabling and starting nginx..."
    maybe_run run_privileged systemctl enable --now nginx
}

# === Legacy certbot-dns-ovh cleanup ======================================
# Older bootstraps used the certbot-dns-ovh Python plugin, which reads
# credentials from /etc/letsencrypt/ovh.ini. We've replaced that flow with
# certbot --manual + hooks/certbot-dns-{auth,cleanup}.sh talking to
# lib/dns_provider.sh (backed by lib/ovh.sh or lib/infomaniak.sh), so the
# .ini file is obsolete. Delete any stale copy left behind by a prior
# install to avoid confusion.
step_remove_legacy_ovh_ini() {
    if [[ -f /etc/letsencrypt/ovh.ini ]]; then
        log_info "Removing legacy /etc/letsencrypt/ovh.ini (now obsolete)..."
        maybe_run run_privileged rm -f /etc/letsencrypt/ovh.ini
    fi
}

# === systemd template units =============================================
step_install_template_units() {
    log_info "Installing systemd template units..."
    maybe_run run_privileged install -m 0644 \
        "${BEBOP_TOOLING_TEMPLATE_DIR}/bebop@.service" \
        /etc/systemd/system/bebop@.service
    maybe_run run_privileged install -m 0644 \
        "${BEBOP_TOOLING_TEMPLATE_DIR}/phoenixd@.service" \
        /etc/systemd/system/phoenixd@.service
    maybe_run run_privileged install -m 0644 \
        "${BEBOP_TOOLING_TEMPLATE_DIR}/mongod@.service" \
        /etc/systemd/system/mongod@.service
    maybe_run run_privileged systemctl daemon-reload
}

# === Tooling libs + per-tenant scripts ==================================
step_install_tooling_libs_and_scripts() {
    log_info "Installing tooling libs to ${BEBOP_TOOLING_INSTALL_PREFIX}..."
    maybe_run run_privileged install -d -m 0755 "${BEBOP_TOOLING_INSTALL_PREFIX}/lib"
    maybe_run run_privileged install -d -m 0755 "${BEBOP_TOOLING_INSTALL_PREFIX}/templates"
    maybe_run run_privileged install -d -m 0755 "${BEBOP_TOOLING_INSTALL_PREFIX}/hooks"
    local f
    for f in "${BEBOP_TOOLING_LIB_DIR}"/*.sh "${BEBOP_TOOLING_LIB_DIR}"/*.py; do
        [[ -f "$f" ]] || continue
        maybe_run run_privileged install -m 0644 "$f" "${BEBOP_TOOLING_INSTALL_PREFIX}/lib/"
    done
    for f in "${BEBOP_TOOLING_TEMPLATE_DIR}"/*; do
        maybe_run run_privileged install -m 0644 "$f" "${BEBOP_TOOLING_INSTALL_PREFIX}/templates/"
    done
    # certbot --manual hooks: must be executable.
    local hooks_src="${SCRIPT_DIR}/hooks"
    if [[ -d "$hooks_src" ]]; then
        for f in "$hooks_src"/*.sh; do
            [[ -f "$f" ]] || continue
            maybe_run run_privileged install -m 0755 "$f" "${BEBOP_TOOLING_INSTALL_PREFIX}/hooks/"
        done
    fi
    log_info "Installing per-tenant scripts to /usr/local/bin/..."
    local script
    for script in add-tenant.sh remove-tenant.sh migrate-tenant.sh upgrade-tenant.sh upgrade-all.sh list-tenants.sh find-orphans.sh mail-relay-ctl.sh mail-relay-upstream-sync.sh tenant-cli.sh gh-rate-limit.sh certbot-renew-check.sh backup-tenants.sh backup-tooling.sh restore-tenant.sh restore-tooling.sh freeze-tenant.sh bebop-exit-handler.sh bebop-exit-worker.sh bebop-mongo-preflight.sh bebop-mail-relay-preflight.sh test-tenant-reaper.sh; do
        if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
            maybe_run run_privileged install -m 0755 "${SCRIPT_DIR}/${script}" "/usr/local/bin/${script}"
        else
            log_warn "skipping /usr/local/bin/${script} — source not present yet (expected during early dev)"
        fi
    done
}

# === Nightly fleet upgrade timer (optional) ============================
# Installs bebop-upgrade-all.{service,timer} unconditionally (cheap, no
# behavior unless the timer is enabled). Then enables OR disables the
# timer based on BEBOP_NIGHTLY_UPGRADE_ENABLED in secrets.env. Toggling
# the var + re-running host-bootstrap.sh is the supported on/off switch.
step_setup_nightly_upgrade() {
    log_info "Installing bebop-upgrade-all.{service,timer} units..."
    local u
    for u in bebop-upgrade-all.service bebop-upgrade-all.timer; do
        maybe_run run_privileged install -m 0644 \
            "${BEBOP_TOOLING_TEMPLATE_DIR}/${u}" "/etc/systemd/system/${u}"
    done
    maybe_run run_privileged systemctl daemon-reload
    case "${BEBOP_NIGHTLY_UPGRADE_ENABLED:-}" in
        true|1|yes|on)
            log_info "BEBOP_NIGHTLY_UPGRADE_ENABLED=true — enabling bebop-upgrade-all.timer (daily 04:00)"
            maybe_run run_privileged systemctl enable --now bebop-upgrade-all.timer
            ;;
        *)
            log_info "BEBOP_NIGHTLY_UPGRADE_ENABLED unset/false — keeping bebop-upgrade-all.timer disabled"
            maybe_run run_privileged systemctl disable --now bebop-upgrade-all.timer 2>/dev/null || true
            ;;
    esac
}

# === Registry ==========================================================
step_init_registry() {
    log_info "Initialising tenant registry..."
    registry_init
}

# === Uptime Kuma + Netdata =============================================
step_setup_docker() {
    if ! systemctl is-active --quiet docker; then
        log_info "Enabling and starting docker..."
        maybe_run run_privileged systemctl enable --now docker
    else
        log_info "docker already running ✓"
    fi
}

step_install_uptime_kuma() {
    if run_privileged docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'bebop-uptime-kuma'; then
        log_info "Uptime Kuma container already exists ✓"
        if ! run_privileged docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'bebop-uptime-kuma'; then
            maybe_run run_privileged docker start bebop-uptime-kuma
        fi
        return 0
    fi
    log_info "Pulling ${UPTIME_KUMA_IMAGE}..."
    maybe_run run_privileged docker pull "${UPTIME_KUMA_IMAGE}"
    maybe_run run_privileged install -d -m 0755 /var/lib/uptime-kuma
    log_info "Starting Uptime Kuma container on 127.0.0.1:${UPTIME_KUMA_HOST_PORT}..."
    maybe_run run_privileged docker run -d \
        --name bebop-uptime-kuma \
        --restart=always \
        -v /var/lib/uptime-kuma:/app/data \
        -p "127.0.0.1:${UPTIME_KUMA_HOST_PORT}:3001" \
        "${UPTIME_KUMA_IMAGE}"
}

# === Kuma Python venv (uptime-kuma-api) ================================
step_install_kuma_python_env() {
    local venv=/opt/be-BOP-tooling/kuma-venv
    if [[ -x "$venv/bin/python" ]] \
        && run_privileged "$venv/bin/python" -c 'import uptime_kuma_api' 2>/dev/null; then
        log_info "Kuma Python venv already provisioned at ${venv} ✓"
        return 0
    fi
    log_info "Creating Python venv at ${venv} with uptime-kuma-api..."
    maybe_run run_privileged python3 -m venv "$venv"
    maybe_run run_privileged "$venv/bin/pip" install --quiet --upgrade pip
    maybe_run run_privileged "$venv/bin/pip" install --quiet 'uptime-kuma-api>=1.2'
}

# === Kuma admin auto-provisioning ======================================
step_setup_kuma_admin() {
    local admin_file=/etc/be-BOP-tooling/kuma-admin.env
    if [[ -f "$admin_file" ]]; then
        log_info "Kuma admin credentials file already exists at ${admin_file} ✓"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would auto-provision Kuma admin and write ${admin_file}"
        return 0
    fi
    # Wait for Kuma to be reachable (it just started; needs a few seconds).
    local kuma_url="http://127.0.0.1:${UPTIME_KUMA_HOST_PORT}"
    log_info "Waiting for Kuma to become reachable at ${kuma_url}..."
    local i ready=false
    for (( i=1; i<=60; i++ )); do
        if curl -sf --max-time 2 "${kuma_url}/" >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done
    if [[ "$ready" != "true" ]]; then
        die "Kuma did not become reachable at ${kuma_url} within 120s"
    fi
    log_info "Kuma reachable; provisioning admin via uptime-kuma-api..."
    local user="bebop-admin"
    local pass
    pass=$(openssl rand -base64 33 | tr -d '+/=\n' | head -c 32)

    local cli="${BEBOP_TOOLING_LIB_DIR}/kuma-cli.py"
    local venv_python=/opt/be-BOP-tooling/kuma-venv/bin/python
    if ! run_privileged "$venv_python" "$cli" \
            --url "$kuma_url" setup-admin \
            --user "$user" --password "$pass"; then
        die "kuma: setup-admin failed (see kuma-cli output above)"
    fi
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# Auto-generated by host-bootstrap.sh — DO NOT edit by hand.
# Used by lib/uptime-kuma.sh via add-tenant.sh / remove-tenant.sh.
KUMA_ADMIN_USER="${user}"
KUMA_ADMIN_PASSWORD="${pass}"
EOF
    run_privileged install -m 0600 "$tmp" "$admin_file"
    rm -f "$tmp"
    log_info "Kuma admin credentials saved to ${admin_file} (mode 0600)"
}

# === Kuma notification channels (SMTP + Zulip) =========================
step_setup_kuma_notifications() {
    if [[ "$DEFER_SECRETS" == "true" && -z "${SMTP_HOST:-}${ZULIP_SITE:-}" ]]; then
        log_info "Skipping Kuma notifications setup (--defer-secrets)"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would configure Kuma SMTP + Zulip notification channels"
        return 0
    fi
    local admin_file=/etc/be-BOP-tooling/kuma-admin.env
    if [[ ! -f "$admin_file" ]]; then
        log_warn "Kuma admin file ${admin_file} not found; skipping notifications setup"
        return 0
    fi
    # shellcheck disable=SC1090
    source "$admin_file"
    local kuma_url="http://127.0.0.1:${UPTIME_KUMA_HOST_PORT}"
    local cli="${BEBOP_TOOLING_LIB_DIR}/kuma-cli.py"
    local venv_python=/opt/be-BOP-tooling/kuma-venv/bin/python
    log_info "Configuring Kuma notification channels (SMTP + Zulip)..."
    # Pass the env explicitly through `env` so the Python child sees them,
    # whether host-bootstrap runs as root (most common — env passes naturally)
    # or via sudo (where env_reset would otherwise strip these).
    run_privileged env \
        SMTP_HOST="${SMTP_HOST:-}" \
        SMTP_PORT="${SMTP_PORT:-587}" \
        SMTP_USER="${SMTP_USER:-}" \
        SMTP_PASSWORD="${SMTP_PASSWORD:-}" \
        SMTP_FROM="${SMTP_FROM:-}" \
        SMTP_TO="${SMTP_TO:-}" \
        ZULIP_SITE="${ZULIP_SITE:-}" \
        ZULIP_BOT_EMAIL="${ZULIP_BOT_EMAIL:-}" \
        ZULIP_BOT_API_KEY="${ZULIP_BOT_API_KEY:-}" \
        ZULIP_STREAM="${ZULIP_STREAM:-bebop-tooling}" \
        ZULIP_TOPIC="${ZULIP_TOPIC:-kuma alerts}" \
        "$venv_python" "$cli" --url "$kuma_url" setup-notifications \
            --user "$KUMA_ADMIN_USER" --password "$KUMA_ADMIN_PASSWORD" \
        || log_warn "kuma: setup-notifications had issues (see output above)"
}

step_install_netdata() {
    if systemctl is-active --quiet netdata; then
        log_info "netdata already running ✓"
        return 0
    fi
    log_info "Enabling and starting netdata..."
    maybe_run run_privileged systemctl enable --now netdata
}

# === Netdata public reverse-proxy (optional, opt-in via secrets.env) ====
# When NETDATA_PUBLIC_HOSTNAME is set, expose the Netdata UI publicly
# behind nginx + Let's Encrypt + HTTP basic auth. The hostname must
# resolve under BEBOP_DNS_ZONE; we create the A record + cert via the
# configured DNS provider, generate a random admin password, and configure the vhost.
step_setup_netdata_public_access() {
    if [[ -z "${NETDATA_PUBLIC_HOSTNAME:-}" ]]; then
        log_info "NETDATA_PUBLIC_HOSTNAME unset — Netdata stays local-only (SSH tunnel for access)"
        return 0
    fi
    if [[ "$DEFER_SECRETS" == "true" ]] && ! dns_provider_is_configured; then
        log_info "Skipping Netdata public access (--defer-secrets)"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would expose Netdata at https://${NETDATA_PUBLIC_HOSTNAME}/"
        return 0
    fi
    local zone="${BEBOP_DNS_ZONE:-}"
    local hostname="$NETDATA_PUBLIC_HOSTNAME"
    if [[ -z "$zone" ]]; then
        die "NETDATA_PUBLIC_HOSTNAME set but BEBOP_DNS_ZONE is empty"
    fi
    if [[ "$hostname" != *".${zone}" ]]; then
        die "NETDATA_PUBLIC_HOSTNAME=${hostname} must be within BEBOP_DNS_ZONE=${zone}"
    fi
    local sub="${hostname%.${zone}}"

    # 1. DNS A record (idempotent — dns_provider_dns_record_create returns the
    #    existing id if a matching record already exists).
    local host_ip
    host_ip="${BEBOP_HOST_IP:-}"
    if [[ -z "$host_ip" ]]; then
        host_ip=$(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$host_ip" || ! "$host_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        die "could not detect host public IP (set BEBOP_HOST_IP in env to override)"
    fi
    log_info "Ensuring DNS A record ${hostname} -> ${host_ip}..."
    dns_provider_dns_record_create "$sub" A "$host_ip" >/dev/null
    dns_provider_dns_zone_refresh

    # 2. TLS cert (single-domain, via our certbot --manual hooks).
    if run_privileged test -d /etc/letsencrypt/live/netdata-host; then
        log_info "Cert netdata-host already issued ✓"
    else
        local acme_email="${LE_OPERATOR_EMAIL:-${ADMIN_EMAIL:-}}"
        if [[ -z "$acme_email" ]]; then
            log_warn "No LE_OPERATOR_EMAIL (or ADMIN_EMAIL) — Netdata cert NOT issued"
            log_warn "Set LE_OPERATOR_EMAIL in secrets.env and re-run this script to finish"
            return 0
        fi
        local hooks_dir="${SCRIPT_DIR}/hooks"
        if [[ ! -d "$hooks_dir" ]]; then
            hooks_dir="${BEBOP_TOOLING_INSTALL_PREFIX}/hooks"
        fi
        log_info "Issuing Let's Encrypt cert for ${hostname} (DNS-01 via provider hooks)..."
        run_privileged certbot certonly \
            --manual \
            --preferred-challenges dns-01 \
            --manual-auth-hook "${hooks_dir}/certbot-dns-auth.sh" \
            --manual-cleanup-hook "${hooks_dir}/certbot-dns-cleanup.sh" \
            --non-interactive --agree-tos \
            --email "$acme_email" \
            --cert-name netdata-host \
            -d "$hostname"
    fi

    # 3. Basic-auth credentials. Persist them so re-runs reuse the same.
    local admin_file=/etc/be-BOP-tooling/netdata-admin.env
    local user="netdata-admin" pass=""
    if [[ -f "$admin_file" ]]; then
        # shellcheck disable=SC1090
        source "$admin_file"
        user="${NETDATA_ADMIN_USER:-netdata-admin}"
        pass="${NETDATA_ADMIN_PASSWORD:-}"
    fi
    if [[ -z "$pass" ]]; then
        pass=$(openssl rand -base64 33 | tr -d '+/=\n' | head -c 32)
        local tmp
        tmp=$(mktemp)
        cat > "$tmp" <<EOF
# Auto-generated by host-bootstrap.sh — DO NOT edit by hand.
NETDATA_ADMIN_USER="${user}"
NETDATA_ADMIN_PASSWORD="${pass}"
EOF
        run_privileged install -m 0600 "$tmp" "$admin_file"
        rm -f "$tmp"
        log_info "Generated Netdata admin credentials → ${admin_file} (mode 0600)"
    else
        log_info "Reusing existing Netdata admin credentials from ${admin_file}"
    fi

    # 4. nginx htpasswd file.
    if ! command -v htpasswd >/dev/null 2>&1; then
        die "htpasswd not installed (apache2-utils) — cannot configure Netdata basic auth"
    fi
    log_info "Writing /etc/nginx/.netdata-htpasswd..."
    run_privileged htpasswd -B -b -c /etc/nginx/.netdata-htpasswd "$user" "$pass" >/dev/null
    run_privileged chmod 0640 /etc/nginx/.netdata-htpasswd
    run_privileged chown root:www-data /etc/nginx/.netdata-htpasswd 2>/dev/null || true

    # 5. nginx vhost.
    log_info "Installing nginx vhost for ${hostname}..."
    local tmpl="${BEBOP_TOOLING_TEMPLATE_DIR}/nginx-netdata.conf.tmpl"
    local rev="2026050601"
    local tmp
    tmp=$(mktemp)
    sed -e "s|@netdata_hostname@|${hostname}|g" \
        -e "s|@template_revision@|${rev}|g" \
        "$tmpl" > "$tmp"
    run_privileged install -m 0644 "$tmp" /etc/nginx/sites-available/netdata.conf
    run_privileged ln -sfn /etc/nginx/sites-available/netdata.conf /etc/nginx/sites-enabled/netdata.conf
    rm -f "$tmp"

    _nginx_quarantine_broken_vhosts
    if ! run_privileged nginx -t 2>/dev/null; then
        die "nginx -t failed after installing the netdata vhost"
    fi
    run_privileged systemctl reload nginx
    log_info "Netdata public access ready at https://${hostname}/ (creds in ${admin_file})"
}

# === Kuma public reverse-proxy (optional, opt-in via secrets.env) =======
# When KUMA_PUBLIC_HOSTNAME is set, expose the Uptime Kuma UI publicly
# behind nginx + Let's Encrypt. No extra basic-auth — Kuma has its own
# admin login (auto-provisioned at /etc/be-BOP-tooling/kuma-admin.env).
step_setup_kuma_public_access() {
    if [[ -z "${KUMA_PUBLIC_HOSTNAME:-}" ]]; then
        log_info "KUMA_PUBLIC_HOSTNAME unset — Kuma stays local-only (SSH tunnel for access)"
        return 0
    fi
    if [[ "$DEFER_SECRETS" == "true" ]] && ! dns_provider_is_configured; then
        log_info "Skipping Kuma public access (--defer-secrets)"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would expose Kuma at https://${KUMA_PUBLIC_HOSTNAME}/"
        return 0
    fi
    local zone="${BEBOP_DNS_ZONE:-}"
    local hostname="$KUMA_PUBLIC_HOSTNAME"
    if [[ -z "$zone" ]]; then
        die "KUMA_PUBLIC_HOSTNAME set but BEBOP_DNS_ZONE is empty"
    fi
    if [[ "$hostname" != *".${zone}" ]]; then
        die "KUMA_PUBLIC_HOSTNAME=${hostname} must be within BEBOP_DNS_ZONE=${zone}"
    fi
    local sub="${hostname%.${zone}}"

    # 1. DNS A record (idempotent).
    local host_ip="${BEBOP_HOST_IP:-}"
    if [[ -z "$host_ip" ]]; then
        host_ip=$(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$host_ip" || ! "$host_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        die "could not detect host public IP (set BEBOP_HOST_IP in env to override)"
    fi
    log_info "Ensuring DNS A record ${hostname} -> ${host_ip}..."
    dns_provider_dns_record_create "$sub" A "$host_ip" >/dev/null
    dns_provider_dns_zone_refresh

    # 2. TLS cert (single-domain, via certbot --manual + our hooks).
    if run_privileged test -d /etc/letsencrypt/live/kuma-host; then
        log_info "Cert kuma-host already issued ✓"
    else
        local acme_email="${LE_OPERATOR_EMAIL:-${ADMIN_EMAIL:-}}"
        if [[ -z "$acme_email" ]]; then
            log_warn "No LE_OPERATOR_EMAIL (or ADMIN_EMAIL) — Kuma cert NOT issued"
            log_warn "Set LE_OPERATOR_EMAIL in secrets.env and re-run this script to finish"
            return 0
        fi
        local hooks_dir="${SCRIPT_DIR}/hooks"
        if [[ ! -d "$hooks_dir" ]]; then
            hooks_dir="${BEBOP_TOOLING_INSTALL_PREFIX}/hooks"
        fi
        log_info "Issuing Let's Encrypt cert for ${hostname} (DNS-01 via provider hooks)..."
        run_privileged certbot certonly \
            --manual \
            --preferred-challenges dns-01 \
            --manual-auth-hook "${hooks_dir}/certbot-dns-auth.sh" \
            --manual-cleanup-hook "${hooks_dir}/certbot-dns-cleanup.sh" \
            --non-interactive --agree-tos \
            --email "$acme_email" \
            --cert-name kuma-host \
            -d "$hostname"
    fi

    # 3. nginx vhost.
    log_info "Installing nginx vhost for ${hostname}..."
    local tmpl="${BEBOP_TOOLING_TEMPLATE_DIR}/nginx-kuma.conf.tmpl"
    local rev="2026050601"
    local tmp
    tmp=$(mktemp)
    sed -e "s|@kuma_hostname@|${hostname}|g" \
        -e "s|@kuma_host_port@|${UPTIME_KUMA_HOST_PORT}|g" \
        -e "s|@template_revision@|${rev}|g" \
        "$tmpl" > "$tmp"
    run_privileged install -m 0644 "$tmp" /etc/nginx/sites-available/kuma.conf
    run_privileged ln -sfn /etc/nginx/sites-available/kuma.conf /etc/nginx/sites-enabled/kuma.conf
    rm -f "$tmp"

    _nginx_quarantine_broken_vhosts
    if ! run_privileged nginx -t 2>/dev/null; then
        die "nginx -t failed after installing the kuma vhost"
    fi
    run_privileged systemctl reload nginx
    log_info "Kuma public access ready at https://${hostname}/ (login with creds in /etc/be-BOP-tooling/kuma-admin.env)"
}

# === Test-tenant deploy API (optional, opt-in via secrets.env) ==========
# Gated by BEBOP_DEPLOY_API_ENABLED=true. Has two layers:
#   1. ALWAYS, when enabled: HMAC secret + systemd daemon (loopback-bound
#      on 127.0.0.1:8820 by default) + reaper timer. URL for callers on
#      the same VDS: http://127.0.0.1:8820/deploy-test-tenant
#   2. ADDITIONALLY when BEBOP_DEPLOY_API_HOSTNAME is also set: DNS A
#      record + DNS-01 Let's Encrypt cert + nginx vhost with source-IP
#      whitelist. URL: https://<HOSTNAME>/deploy-test-tenant
#
# All steps idempotent.

# Helper: ensure the HMAC sidecar exists (auto-generated if BEBOP_DEPLOY_API_SECRET
# is empty in secrets.env). Echoes nothing — side effects only.
_deploy_api_ensure_secret() {
    local sidecar=/etc/be-BOP-tooling/deploy-api.env
    if [[ -n "${BEBOP_DEPLOY_API_SECRET:-}" ]]; then
        log_info "Using BEBOP_DEPLOY_API_SECRET from secrets.env"
        # Strip a stale auto-generated sidecar to avoid shadowing the
        # operator's value (sidecar is loaded after secrets.env by the unit).
        if [[ -f "$sidecar" ]] && grep -q '^BEBOP_DEPLOY_API_SECRET=' "$sidecar"; then
            log_warn "removing stale ${sidecar} (operator-provided secret in secrets.env takes precedence)"
            run_privileged rm -f "$sidecar"
        fi
    elif [[ -f "$sidecar" ]] && grep -q '^BEBOP_DEPLOY_API_SECRET=' "$sidecar"; then
        log_info "Reusing existing auto-generated secret in ${sidecar}"
    else
        local gen
        gen=$(openssl rand -hex 32)
        local tmp
        tmp=$(mktemp)
        cat > "$tmp" <<EOF
# Auto-generated by host-bootstrap.sh — DO NOT edit by hand.
# Copy this exact value into the calling be-BOP's webhook settings.
BEBOP_DEPLOY_API_SECRET="${gen}"
EOF
        run_privileged install -m 0600 "$tmp" "$sidecar"
        rm -f "$tmp"
        log_info "Generated deploy-API HMAC secret → ${sidecar} (mode 0600)"
    fi
}

# Helper: install + enable the systemd units (daemon + reaper). Idempotent.
_deploy_api_install_systemd() {
    log_info "Installing bebop-test-tenant-api / -reaper systemd units..."
    local u
    for u in bebop-test-tenant-api.service \
             bebop-test-tenant-reaper.service \
             bebop-test-tenant-reaper.timer; do
        run_privileged install -m 0644 \
            "${BEBOP_TOOLING_TEMPLATE_DIR}/${u}" "/etc/systemd/system/${u}"
    done
    run_privileged systemctl daemon-reload
    run_privileged systemctl enable --now bebop-test-tenant-api.service
    run_privileged systemctl enable --now bebop-test-tenant-reaper.timer
    # See mail-relay note: `enable --now` on an active unit does not
    # re-exec the daemon. try-restart forces a re-exec when active,
    # no-op otherwise. Ensures lib/test-tenant-api.py updates take effect.
    run_privileged systemctl try-restart bebop-test-tenant-api.service
}

# Helper: provision the optional public exposure layer (DNS + cert + nginx
# vhost). Called only when BEBOP_DEPLOY_API_HOSTNAME is set.
_deploy_api_install_public_exposure() {
    local hostname="$1"
    local zone="${BEBOP_DNS_ZONE:-}"
    if [[ -z "$zone" ]]; then
        die "BEBOP_DEPLOY_API_HOSTNAME set but BEBOP_DNS_ZONE is empty"
    fi
    if [[ "$hostname" != *".${zone}" ]]; then
        die "BEBOP_DEPLOY_API_HOSTNAME=${hostname} must be within BEBOP_DNS_ZONE=${zone}"
    fi
    local sub="${hostname%.${zone}}"

    local host_ip="${BEBOP_HOST_IP:-}"
    if [[ -z "$host_ip" ]]; then
        host_ip=$(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$host_ip" || ! "$host_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        die "could not detect host public IP (set BEBOP_HOST_IP in env to override)"
    fi
    log_info "Ensuring DNS A record ${hostname} -> ${host_ip}..."
    dns_provider_dns_record_create "$sub" A "$host_ip" >/dev/null
    dns_provider_dns_zone_refresh

    if run_privileged test -d /etc/letsencrypt/live/bebop-deploy-api; then
        log_info "Cert bebop-deploy-api already issued ✓"
    else
        local acme_email="${LE_OPERATOR_EMAIL:-}"
        if [[ -z "$acme_email" ]]; then
            log_warn "No LE_OPERATOR_EMAIL — deploy API cert NOT issued. Set it in secrets.env and re-run host-bootstrap.sh."
            return 0
        fi
        local hooks_dir="${SCRIPT_DIR}/hooks"
        if [[ ! -d "$hooks_dir" ]]; then
            hooks_dir="${BEBOP_TOOLING_INSTALL_PREFIX}/hooks"
        fi
        log_info "Issuing Let's Encrypt cert for ${hostname} (DNS-01 via provider hooks)..."
        run_privileged certbot certonly \
            --manual \
            --preferred-challenges dns-01 \
            --manual-auth-hook "${hooks_dir}/certbot-dns-auth.sh" \
            --manual-cleanup-hook "${hooks_dir}/certbot-dns-cleanup.sh" \
            --non-interactive --agree-tos \
            --email "$acme_email" \
            --cert-name bebop-deploy-api \
            -d "$hostname"
    fi

    local allow_block
    if [[ -n "${BEBOP_DEPLOY_API_ALLOWED_IPS:-}" ]]; then
        allow_block=""
        local ip
        local IFS_save="$IFS"
        IFS=',' read -ra _ips <<< "$BEBOP_DEPLOY_API_ALLOWED_IPS"
        IFS="$IFS_save"
        for ip in "${_ips[@]}"; do
            ip="${ip// /}"
            [[ -z "$ip" ]] && continue
            allow_block+="        allow ${ip};"$'\n'
        done
        allow_block+="        deny all;"
    else
        allow_block="        allow 127.0.0.1;"$'\n'
        allow_block+="        allow ::1;"$'\n'
        allow_block+="        allow ${host_ip};"$'\n'
        allow_block+="        deny all;"
    fi
    log_info "Installing nginx vhost for ${hostname}..."
    local tmpl="${BEBOP_TOOLING_TEMPLATE_DIR}/nginx-deploy.conf.tmpl"
    local rev="2026062701"
    local daemon_port="${BEBOP_DEPLOY_API_PORT:-8820}"
    local tmp
    tmp=$(mktemp)
    awk -v hostname="$hostname" \
        -v port="$daemon_port" \
        -v rev="$rev" \
        -v allow_block="$allow_block" \
        '{
            gsub(/@deploy_hostname@/, hostname);
            gsub(/@daemon_port@/, port);
            gsub(/@template_revision@/, rev);
            gsub(/@allow_block@/, allow_block);
            print
        }' "$tmpl" > "$tmp"
    run_privileged install -m 0644 "$tmp" /etc/nginx/sites-available/deploy.conf
    run_privileged ln -sfn /etc/nginx/sites-available/deploy.conf /etc/nginx/sites-enabled/deploy.conf
    rm -f "$tmp"

    _nginx_quarantine_broken_vhosts
    if ! run_privileged nginx -t 2>/dev/null; then
        die "nginx -t failed after installing the deploy vhost"
    fi
    run_privileged systemctl reload nginx
    log_info "Deploy API public exposure ready at https://${hostname}/deploy-test-tenant"
}

step_setup_test_tenant_deploy_api() {
    # Backwards-compat: a HOSTNAME without ENABLED still wires things up
    # (operators who configured the API before the ENABLED switch existed).
    local enabled="${BEBOP_DEPLOY_API_ENABLED:-}"
    case "$enabled" in true|1|yes|on) enabled=true ;; *) enabled=false ;; esac
    if [[ "$enabled" != "true" && -z "${BEBOP_DEPLOY_API_HOSTNAME:-}" ]]; then
        log_info "BEBOP_DEPLOY_API_ENABLED not true (and no HOSTNAME) — deploy API NOT installed"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would install test-tenant deploy API daemon"
        [[ -n "${BEBOP_DEPLOY_API_HOSTNAME:-}" ]] && \
            log_info "[dry-run] would expose publicly at https://${BEBOP_DEPLOY_API_HOSTNAME}/"
        return 0
    fi

    _deploy_api_ensure_secret
    _deploy_api_install_systemd

    # Public exposure is optional. We DO want the daemon listening even in
    # local-only mode (loopback). nginx + DNS + cert only when HOSTNAME is set.
    if [[ -n "${BEBOP_DEPLOY_API_HOSTNAME:-}" ]]; then
        if [[ "$DEFER_SECRETS" == "true" ]] && ! dns_provider_is_configured; then
            log_info "Skipping deploy API public exposure (--defer-secrets)"
        else
            _deploy_api_install_public_exposure "$BEBOP_DEPLOY_API_HOSTNAME"
        fi
    else
        log_info "Deploy API local-only: http://127.0.0.1:${BEBOP_DEPLOY_API_PORT:-8820}/deploy-test-tenant"
    fi
    log_info "Reaper sweeping every 5 min (TTL=${BEBOP_TEST_TENANT_TTL_SECONDS:-7200}s)"
}

# === tooling MongoDB ====================================================
# A dedicated `bebop-tooling-mongodb.service` instance holds the state
# used by tools whose scope is host-wide (not per-tenant). Today that
# means the mail-relay (tenants creds, send_log, alert_state). Runs on
# a fixed port well above the per-tenant range so it can never collide
# with allocations.
#
# Explicitly NOT `mongod@tooling.service` — using the per-tenant template
# would let any code that scans by `mongod@<X>` (find-orphans, list-
# tenants, backup-tenants) confuse this host infrastructure with a
# tenant. The distinct service name closes that boundary permanently.
#
# Also migrates away from a previous iteration that DID use
# `mongod@tooling.service`: disables it, removes its port.env, and drops
# its data dir — no merchant data ever landed there.
step_setup_tooling_mongodb() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would install bebop-tooling-mongodb.service and migrate any old mongod@tooling"
        return 0
    fi
    if run_privileged systemctl list-unit-files 'mongod@tooling.service' \
            --no-legend 2>/dev/null | grep -q '^mongod@tooling.service' \
       || run_privileged systemctl is-enabled --quiet mongod@tooling.service 2>/dev/null \
       || run_privileged systemctl is-active --quiet mongod@tooling.service 2>/dev/null; then
        log_info "Migrating away from mongod@tooling.service..."
        run_privileged systemctl disable --now mongod@tooling.service 2>/dev/null || true
        run_privileged rm -f /etc/systemd/system/multi-user.target.wants/mongod@tooling.service
        run_privileged rm -rf /etc/be-BOP-mongodb/tooling /var/lib/be-BOP-mongodb/tooling
        run_privileged systemctl daemon-reload
    fi
    log_info "Provisioning bebop-tooling-mongodb.service..."
    run_privileged install -m 0644 \
        "${BEBOP_TOOLING_TEMPLATE_DIR}/bebop-tooling-mongodb.service" \
        /etc/systemd/system/bebop-tooling-mongodb.service
    run_privileged systemctl daemon-reload
    run_privileged systemctl enable --now bebop-tooling-mongodb.service
    log_info "bebop-tooling-mongodb listening on 127.0.0.1:27100 (db=bebop_tooling)"
}

# === mail-relay =========================================================
# The fake SMTP shim that be-BOP tenants use for outbound mail. Loopback-
# only; forwards to the configured transactional provider (Scaleway TEM in
# V1). State lives on mongod@tooling (see step_setup_tooling_mongodb).
# Idempotent — safe to re-run on updates.
step_setup_mail_relay() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would install bebop-mail-relay + retry timer systemd units"
        return 0
    fi
    log_info "Installing bebop-mail-relay systemd unit..."
    local u
    for u in bebop-mail-relay.service \
             bebop-mail-relay-retry.service \
             bebop-mail-relay-retry.timer \
             bebop-mail-relay-prune.service \
             bebop-mail-relay-prune.timer; do
        run_privileged install -m 0644 \
            "${BEBOP_TOOLING_TEMPLATE_DIR}/${u}" "/etc/systemd/system/${u}"
    done
    run_privileged systemctl daemon-reload
    run_privileged systemctl enable --now bebop-mail-relay.service
    run_privileged systemctl enable --now bebop-mail-relay-retry.timer
    run_privileged systemctl enable --now bebop-mail-relay-prune.timer
    # `enable --now` on an ALREADY active service is a no-op — it doesn't
    # re-exec the daemon, so any change to lib/mail-relay.py that we just
    # installed is NOT picked up. try-restart forces a re-exec when the
    # unit is active, no-op otherwise (fresh install where enable --now
    # just started it). Idempotent.
    run_privileged systemctl try-restart bebop-mail-relay.service
    log_info "bebop-mail-relay listening on 127.0.0.1:2525"
    log_info "bebop-mail-relay-retry sweeping every 15 minutes"
    log_info "bebop-mail-relay-prune firing nightly (03:15 UTC, 90-day retention)"
}

# === Summary ===========================================================
step_print_summary() {
    local title="be-BOP multi-tenant host bootstrap COMPLETE"
    if [[ "$DEFER_SECRETS" == "true" ]] && ! dns_provider_is_configured; then
        title="be-BOP multi-tenant host bootstrap PARTIAL (deferred-secrets mode)"
    fi
    cat <<EOF

==========================================================================
  ${title}
==========================================================================

Versions installed:
  Node.js:    $(node --version 2>/dev/null || echo '?')
  pnpm:       $(pnpm --version 2>/dev/null || echo '?')
  MongoDB:    $(mongod --version 2>/dev/null | head -1 || echo '?')
  mongosh:    $(mongosh --version 2>/dev/null || echo '?')
  Garage:     v${GARAGE_VERSION}
  phoenixd:   ${PHOENIXD_VERSION}
  certbot:    $(certbot --version 2>/dev/null || echo '?')
  docker:     $(docker --version 2>/dev/null || echo '?')

Key paths:
  Tenant registry        /var/lib/be-BOP/tenants.tsv
  Per-tenant config      /etc/be-BOP/<tenant>/config.env
  Per-tenant releases    /var/lib/be-BOP/<tenant>/releases/
  Per-tenant mongod      /var/lib/be-BOP-mongodb/<tenant>/   (state)
                         /etc/be-BOP-mongodb/<tenant>/port.env
  Phoenixd data          /var/lib/phoenixd/<tenant>/.phoenix/
  Garage state           /var/lib/garage/{meta,data}/
  Secrets                ${SECRETS_FILE}    (mode 0600)
  Certbot DNS-01 hooks   ${BEBOP_TOOLING_INSTALL_PREFIX}/hooks/   (dns_provider_* → active DNS_PROVIDER)
  Template units         /etc/systemd/system/{bebop,phoenixd,mongod}@.service
  Tooling libs           ${BEBOP_TOOLING_INSTALL_PREFIX}/lib/

Services running:
  garage.service (single-instance, mutualised)
  nginx.service (catch-all 444; per-tenant vhosts added by add-tenant.sh)
  netdata.service
  bebop-uptime-kuma (Docker, bound to 127.0.0.1:${UPTIME_KUMA_HOST_PORT})

NEXT STEPS:
EOF
    if [[ "$DEFER_SECRETS" == "true" ]] && ! dns_provider_is_configured; then
        cat <<EOF
  0. Edit ${SECRETS_FILE} (mode 0600), then re-run:
       sudo ${BEBOP_TOOLING_INSTALL_PREFIX}/host-bootstrap.sh
     This will verify DNS provider connectivity and auto-provision the
     Kuma admin + notification channels.
EOF
    fi
    cat <<EOF
  1. Add your first tenant:
       add-tenant.sh tenant1 --admin-email merchant1@example.com

  Optional — if you want to log in to the Kuma UI to view dashboards,
  the auto-generated admin credentials are at /etc/be-BOP-tooling/kuma-admin.env
  (mode 0600). Reach the UI via:
       ssh -L ${UPTIME_KUMA_HOST_PORT}:localhost:${UPTIME_KUMA_HOST_PORT} this-host
       open http://localhost:${UPTIME_KUMA_HOST_PORT}

==========================================================================
EOF
}

# === Orchestration =====================================================
main() {
    require_privileges

    step_check_prerequisites
    step_load_secrets
    step_verify_dns_provider_connectivity

    step_install_apt_packages
    step_install_nodejs_pnpm
    step_install_mongodb
    step_install_garage_binary
    step_install_phoenixd_binary

    step_setup_directories
    step_setup_user_be_bop_cli

    step_write_garage_config
    step_write_garage_service
    step_start_garage
    step_provision_garage_layout

    step_write_nginx_default_vhost
    step_start_nginx

    step_remove_legacy_ovh_ini
    step_install_template_units
    step_install_tooling_libs_and_scripts
    step_init_registry

    step_setup_docker
    step_install_uptime_kuma
    step_install_kuma_python_env
    step_setup_kuma_admin
    step_setup_kuma_notifications
    step_install_netdata
    step_setup_netdata_public_access
    step_setup_kuma_public_access

    step_install_certbot_nginx_reload_hook
    step_setup_cert_renewal_monitoring
    step_setup_nightly_upgrade

    step_setup_test_tenant_deploy_api
    step_setup_tooling_mongodb
    step_setup_mail_relay

    step_print_summary
}

main "$@"

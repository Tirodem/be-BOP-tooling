#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# tenant-cli.sh — multi-tenant be-BOP CLI (forked from be-bop-cli on 2026-06-11).
#
# Forked from be-bop-bootstrap/be-bop-cli.sh to operate on a single tenant in
# the multi-tenant stack. The two scripts are kept separate on purpose so v1
# stays untouched. Differences vs. be-bop-cli:
#   - --tenant <id> is required for `release list`, `release install`, `status`
#   - paths: /var/lib/be-BOP/<tenant>/releases/{<tag>,current}  (per-tenant)
#   - service: bebop@<tenant>.service                            (per-tenant)
#   - privilege escalation via lib/sudo.sh's require_privileges  (no root mandate)
#   - tenant validity via lib/registry.sh's registry_get_status  (no ad-hoc awk)
#   - logging via lib/log.sh                                     (consistent with
#     multitenant-tooling siblings; tenant id auto-tagged in log lines)
#   - pnpm install runs HOME=/tmp COREPACK_ENABLE_DOWNLOAD_PROMPT=0
#     (multitenant-tooling pattern; avoids HOME pollution + corepack prompt).

set -eEuo pipefail

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_NAME="tenant-cli"
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1

# Locate libs: source-tree layout when invoked from a checkout, system layout
# once installed under /usr/local/share/be-BOP-tooling.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    BEBOP_TOOLING_LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d /usr/local/share/be-BOP-tooling/lib ]]; then
    BEBOP_TOOLING_LIB_DIR=/usr/local/share/be-BOP-tooling/lib
else
    echo "tenant-cli: cannot locate lib/ directory" >&2
    exit $EXIT_ERROR
fi

BEBOP_TOOLING_SYSLOG_IDENT="bebop-tooling-${SCRIPT_NAME}"
export BEBOP_TOOLING_SYSLOG_IDENT

# shellcheck source=lib/log.sh
source "$BEBOP_TOOLING_LIB_DIR/log.sh"
# shellcheck source=lib/sudo.sh
source "$BEBOP_TOOLING_LIB_DIR/sudo.sh"
# shellcheck source=lib/registry.sh
source "$BEBOP_TOOLING_LIB_DIR/registry.sh"

# GitHub repository for be-BOP releases
readonly BEBOP_GITHUB_REPO="${BEBOP_GITHUB_REPO:-be-BOP-io-SA/be-BOP}"

# Network timeout constants
readonly CURL_CONNECT_TIMEOUT=${CURL_CONNECT_TIMEOUT:-30}
readonly CURL_DOWNLOAD_TIMEOUT=${CURL_DOWNLOAD_TIMEOUT:-600}

# Default command and options
COMMAND="release"
SUBCOMMAND="list"
TENANT_ID=""
RELEASE_VERSION=""
FAIL_IF_LATEST_NOT_INSTALLED=false
NO_RESTART_AFTER_INSTALL=false

die_missing_tool() {
    local tool=$1
    log_error "Required tool '$tool' is not available"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "💡 Missing required tool: $tool" >&2
    echo "" >&2
    echo "To continue, please install the missing tool:" >&2
    case "$tool" in
        curl) echo "  • On Debian/Ubuntu: apt install curl" >&2 ;;
        jq) echo "  • On Debian/Ubuntu: apt install jq" >&2 ;;
        unzip) echo "  • On Debian/Ubuntu: apt install unzip" >&2 ;;
        systemctl) echo "  • systemd is required for service management" >&2 ;;
        corepack|pnpm) echo "  • Node.js ecosystem tools are required for be-BOP" >&2 ;;
        *) echo "  • Please install '$tool' using your system package manager" >&2 ;;
    esac
    echo "" >&2
    echo "After installing the tool, run the command again." >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    exit $EXIT_ERROR
}

die_unknown_release() {
    local release="$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "⚠️ The specified release could not found: $release" >&2
    echo "" >&2
    echo "To see all available releases, run:" >&2
    echo "  ${SCRIPT_NAME} --tenant <id> release list" >&2
    echo "" >&2
    echo "(The release ID is shown in the first column of the output.)" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "If you need assistance, please share the full command output with us." >&2
    echo "" >&2
    echo "🪪 Contact options:" >&2
    echo "    - Email: contact@be-bop.io" >&2
    echo "    - Nostr: npub16l9pnrkhhagkucjhxvvztz2czv9ex8s5u7yg80ghw9ccjp4j25pqaku4ha" >&2
    echo "" >&2
    echo "📡 Follow updates and tooling improvements at:" >&2
    echo "    → https://be-bop.io/release-note" >&2
    echo "" >&2
    echo "Thank you for helping us make things better — and for being a friendly human. 🤝" >&2
    exit $EXIT_ERROR
}

list_tools_for_command() {
    case "$COMMAND" in
        "release") echo "curl jq unzip corepack pnpm systemctl" ;;
        "status") echo "curl jq systemctl" ;;
        *) echo "" ;;
    esac
}

check_required_tools() {
    local tools_needed
    tools_needed=$(list_tools_for_command)
    for tool in $tools_needed; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            die_missing_tool "$tool"
        fi
    done
}

show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - be-BOP Multi-Tenant Command Line Interface

USAGE:
    $SCRIPT_NAME --tenant <id> [OPTIONS] [COMMAND]

DESCRIPTION:
    Multi-tenant command-line interface for managing one be-BOP tenant.
    Forked from be-bop-cli (v1 single-tenant). All paths and the systemd
    service are scoped to the tenant given via --tenant.

    Privileged operations (release install, service restart) are escalated
    automatically via sudo; you can also run the whole command under sudo.

COMMANDS:
    help                    Show this help message
    release                 Manage be-BOP releases for the tenant
        list                List available releases (default)
        install [version]   Install specific version or latest.
                            version may be:
                              - a release tag (e.g. rel/2025-12-17/bfe5008)
                              - "latest" (default)
                              - "branch=<branch_name>" to install a feature branch
    status                  Show be-BOP status for the tenant

OPTIONS:
    --tenant <id>           Tenant id (required for release & status commands)
    --help, -h              Show this help message
    --version, -v           Show version information
    --fail-if-latest-release-not-installed
                            (status only) Exit with error if latest release not installed
    --no-restart-after-install
                            (install only) Don't restart bebop@<tenant> after installation
    --verbose               Enable detailed logging output

EXAMPLES:
    # List all available releases for tenant 'demo'
    $SCRIPT_NAME --tenant demo release list

    # Install the latest release for tenant 'demo'
    $SCRIPT_NAME --tenant demo release install

    # Install a specific release tag for tenant 'demo'
    $SCRIPT_NAME --tenant demo release install rel/2025-12-17/bfe5008

    # Install a feature branch for tenant 'demo'
    $SCRIPT_NAME --tenant demo release install branch=feature/my_branch
EOF
}

show_version() {
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
}

parse_cli_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h|help)
                COMMAND="help"
                shift
                ;;
            --version)
                COMMAND="version"
                shift
                ;;
            --tenant)
                if [[ $# -lt 2 || "$2" =~ ^- ]]; then
                    die "--tenant requires an argument"
                fi
                TENANT_ID="$2"
                shift 2
                ;;
            --fail-if-latest-release-not-installed)
                FAIL_IF_LATEST_NOT_INSTALLED=true
                shift
                ;;
            --no-restart-after-install)
                NO_RESTART_AFTER_INSTALL=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            release)
                COMMAND="release"
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    case "$1" in
                        list)
                            SUBCOMMAND="list"
                            shift
                            ;;
                        install)
                            SUBCOMMAND="install"
                            shift
                            if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                                RELEASE_VERSION="$1"
                                shift
                            fi
                            ;;
                        *)
                            die "unknown release subcommand: $1 (use --help)"
                            ;;
                    esac
                fi
                ;;
            status)
                COMMAND="status"
                shift
                ;;
            *)
                die "unknown option or command: $1 (use --help)"
                ;;
        esac
    done
}

require_tenant() {
    if [[ -z "$TENANT_ID" ]]; then
        die "--tenant <id> is required for this command (use --help)"
    fi
    if [[ ! "$TENANT_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "tenant id '$TENANT_ID' is not a valid slug (must match [a-z0-9][a-z0-9-]*)"
    fi
    # Tag every subsequent log line with this tenant.
    BEBOP_TOOLING_TENANT_ID="$TENANT_ID"
    export BEBOP_TOOLING_TENANT_ID
}

# validate_tenant: confirm the tenant exists in the registry and is active.
validate_tenant() {
    local status
    status="$(registry_get_status "$TENANT_ID")"
    case "$status" in
        active)        log_debug "tenant '$TENANT_ID' is active" ;;
        absent)        die "tenant '$TENANT_ID' not found in registry (${REGISTRY_PATH})" ;;
        soft-deleted)  die "tenant '$TENANT_ID' is soft-deleted; reactivate it via add-tenant.sh --reactivate first" ;;
        archived)      die "tenant '$TENANT_ID' is archived (data off-loaded)" ;;
        *)             die "tenant '$TENANT_ID' has unexpected status '$status'" ;;
    esac
}

# scope_check: validate tenant + escalate privileges where the subcommand needs them.
scope_check() {
    case "$COMMAND,$SUBCOMMAND" in
        help,*|version,*)
            ;;
        release,list|status,*)
            require_tenant
            validate_tenant
            ;;
        release,install)
            require_tenant
            validate_tenant
            require_privileges
            ;;
    esac
}

# This function retrieves all be-BOP releases from GitHub and extracts latest release metadata
# This function exports the following variables:
#   - ALL_RELEASES_SUMMARY: An opinionated summary of some be-BOP releases suitable for display
#   - RELEASE_META: The latest be-BOP release metadata (JSON, extracted from first release)
fetch_all_releases() {
    log_debug "Fetching all be-BOP releases from GitHub..."

    local curl_args=(
        "--connect-timeout" "$CURL_CONNECT_TIMEOUT"
        "--fail"
        "--location"
        "--max-time" "$CURL_DOWNLOAD_TIMEOUT"
        "--show-error"
        "--silent"
    )

    local url="https://api.github.com/repos/${BEBOP_GITHUB_REPO}/releases"
    local releases_data
    if ! releases_data="$(curl "${curl_args[@]}" "$url" 2>/dev/null)"; then
        die "failed to fetch releases from GitHub (check internet connectivity)"
    fi

    if [[ -z "$releases_data" ]]; then
        die "received empty response from GitHub releases API"
    fi

    local jq_filter1='.[] | "\(.tag_name) - \(.name) (\(.published_at | split("T")[0]))"'
    export ALL_RELEASES_SUMMARY="$(echo "$releases_data" | jq -r "$jq_filter1")"
    local jq_filter2='
      .[]
      | (.assets |= map(
        select(.name | test("be-BOP\\.release\\.[0-9]{4}-[0-9]{2}-[0-9]{2}\\.[a-f0-9]+.*\\.zip"))
        | {name, browser_download_url}))
      | {
        tag_name,
        name,
        published_at: (.published_at | split("T")[0]),
        asset_name: .assets[0].name, asset_url: .assets[0].browser_download_url
      }
    '
    export RELEASE_META="$(echo "$releases_data" | jq -r "$jq_filter2" | jq -s)"
    if [[ -z "$RELEASE_META" ]]; then
        die "could not find valid be-BOP release asset in GitHub response"
    fi
    local latest_release_name latest_release_tag
    latest_release_name="$(echo "$RELEASE_META" | jq -r '.[0].name')"
    latest_release_tag="$(echo "$RELEASE_META" | jq -r '.[0].tag_name')"
    log_debug "Latest release: $latest_release_name ($latest_release_tag)"
}

tenant_releases_dir() {
    printf '/var/lib/be-BOP/%s/releases' "$TENANT_ID"
}

tenant_current_symlink() {
    printf '/var/lib/be-BOP/%s/releases/current' "$TENANT_ID"
}

list_releases() {
    log_info "Fetching available be-BOP releases..."
    fetch_all_releases

    local current_link current_installed=""
    current_link="$(tenant_current_symlink)"
    if [[ -L "$current_link" ]]; then
        current_installed="$(basename "$(readlink -f "$current_link")")"
    fi
    local latest_name latest_asset latest_tag
    latest_name="$(echo "$RELEASE_META" | jq -r '.[0].name')"
    latest_asset="$(echo "$RELEASE_META" | jq -r '.[0].asset_name | sub("\\.zip$"; "")')"
    latest_tag="$(echo "$RELEASE_META" | jq -r '.[0].tag_name')"

    echo ""
    echo "Tenant: ${TENANT_ID}"
    echo "Available be-BOP releases:"
    echo "$ALL_RELEASES_SUMMARY" | head -10
    echo ""

    if [[ -n "$current_installed" ]]; then
        if [[ "$current_installed" = "$latest_asset" ]]; then
            echo "Current installation: ✓ $latest_asset ($latest_tag - $latest_name)"
        else
            echo "Current installation: $current_installed"
            echo "Latest available: ⚠ $latest_asset ($latest_tag - $latest_name)"
        fi
    else
        echo "Current installation: ✗ No be-BOP release installed for tenant '${TENANT_ID}'"
        echo "Latest available: $latest_tag"
    fi
}

install_release() {
    local target_version="${RELEASE_VERSION:-}"

    if [[ -z "${RELEASE_META:-}" ]]; then
        fetch_all_releases
    fi

    local target_url
    local target_name
    case "$target_version" in
      ""|latest)
        target_url="$(echo "$RELEASE_META" | jq -r '.[0].asset_url')"
        target_name="$(echo "$RELEASE_META" | jq -r '.[0].asset_name | sub("\\.zip$"; "")')"
        ;;
      branch=*)
        local branch_name="${target_version#branch=}"
        # GitHub's artifact.ci encodes '/' as '__' in branch names.
        branch_name="${branch_name//\//__}"
        target_url="https://www.artifact.ci/artifact/view/be-BOP-io-SA/be-BOP/branch/$branch_name/be-BOP-release/be-BOP-release.zip"
        target_name="$branch_name"
        ;;
      *)
        local target_meta
        target_meta="$(echo "$RELEASE_META" | jq -r 'first(.[]|select(.tag_name == "'"$target_version"'"))')"
        target_url="$(echo "$target_meta" | jq -r '.asset_url')"
        target_name="$(echo "$target_meta" | jq -r '.asset_name | sub("\\.zip$"; "")')"
        ;;
    esac

    if [[ -z "$target_url" || "$target_url" = "null" ]]; then
        die_unknown_release "$target_version"
    fi

    local releases_dir target_dir
    releases_dir="$(tenant_releases_dir)"
    target_dir="${releases_dir}/${target_name}"
    if [[ -d "$target_dir" && -f "$target_dir/.bebop_install_success" ]]; then
        log_info "release ${target_name} already installed for tenant '${TENANT_ID}'"
        return 0
    fi

    # Download + extract in a user-owned tmp dir.
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    log_info "downloading release ${target_name}..."
    log_debug "download URL: ${target_url}"
    local curl_args=(
        "--connect-timeout" "$CURL_CONNECT_TIMEOUT"
        "--fail"
        "--location"
        "--max-time" "$CURL_DOWNLOAD_TIMEOUT"
        "--progress-bar"
        "--show-error"
        "--output" "${tmp}/be-BOP-update.zip"
    )
    if ! curl "${curl_args[@]}" "$target_url"; then
        die "failed to download be-BOP release (check internet connectivity)"
    fi

    log_debug "extracting release archive..."
    if ! ( cd "$tmp" && unzip -q be-BOP-update.zip ); then
        die "failed to extract be-BOP release archive"
    fi

    local extracted_dir
    extracted_dir=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name "be-BOP release *" | head -1)
    if [[ -z "$extracted_dir" ]]; then
        die "could not find extracted directory for be-BOP release"
    fi

    # Move the extracted tree into the per-tenant releases dir (privileged).
    run_privileged install -d -m 0755 "$releases_dir"
    if run_privileged test -d "$target_dir"; then
        log_debug "removing stalled installation directory ${target_dir}"
        run_privileged rm -rf "$target_dir"
    fi
    run_privileged mv "$extracted_dir" "$target_dir"
    run_privileged chown -R root:root "$target_dir"

    # Install dependencies (matches lib/release.sh's pattern in add-tenant /
    # upgrade-tenant: HOME=/tmp to avoid root HOME pollution,
    # COREPACK_ENABLE_DOWNLOAD_PROMPT=0 to keep pnpm install non-interactive).
    log_info "installing dependencies for ${target_name}..."
    if ! ( cd "$target_dir" && run_privileged env \
            HOME=/tmp COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
            pnpm install --prod --frozen-lockfile ); then
        die "failed to install be-BOP dependencies"
    fi
    run_privileged touch "$target_dir/.bebop_install_success"
    log_info "release ${target_name} installed at ${target_dir}"

    # Atomically swap the 'current' symlink (sibling temp link + mv -T).
    local current_link tmp_link
    current_link="$(tenant_current_symlink)"
    tmp_link="${releases_dir}/.current.$$"
    run_privileged ln -sfn "$target_name" "$tmp_link"
    run_privileged mv -T "$tmp_link" "$current_link"
    log_info "activated ${target_name} as current release for tenant '${TENANT_ID}'"

    # Restart the per-tenant bebop service (unless disabled).
    local service="bebop@${TENANT_ID}.service"
    if [[ "$NO_RESTART_AFTER_INSTALL" = false ]]; then
        if run_privileged systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "restarting ${service}..."
            if ! run_privileged systemctl restart "$service"; then
                log_warn "failed to restart ${service}; restart manually if needed"
            else
                log_info "${service} restarted"
            fi
        elif run_privileged systemctl is-enabled --quiet "$service" 2>/dev/null; then
            log_info "starting ${service}..."
            if ! run_privileged systemctl start "$service"; then
                log_warn "failed to start ${service}; start manually if needed"
            else
                log_info "${service} started"
            fi
        else
            log_debug "${service} not configured; skipping restart"
        fi
    else
        log_info "skipping ${service} restart (--no-restart-after-install)"
    fi
}

show_status() {
    local exit_code=0
    local current_installed=""
    local current_link service
    current_link="$(tenant_current_symlink)"
    service="bebop@${TENANT_ID}.service"

    echo "be-BOP status (tenant: ${TENANT_ID}):"
    echo ""

    if [[ -L "$current_link" ]]; then
        current_installed=$(basename "$(readlink -f "$current_link")")
        echo "Installed release: $current_installed"
        if [[ -f "$(tenant_releases_dir)/$current_installed/.bebop_install_success" ]]; then
            echo "Installation status: ✓ Complete"
        else
            echo "Installation status: ⚠ Incomplete"
            exit_code=1
        fi
    else
        echo "Installation status: ✗ Not installed"
        exit_code=1
    fi

    if fetch_all_releases 2>/dev/null; then
        local latest_name latest_tag latest_asset
        latest_name="$(echo "$RELEASE_META" | jq -r '.[0].name')"
        latest_tag="$(echo "$RELEASE_META" | jq -r '.[0].tag_name')"
        latest_asset="$(echo "$RELEASE_META" | jq -r '.[0].asset_name | sub("\\.zip$"; "")')"

        if [[ -n "$current_installed" ]]; then
            if [[ "$current_installed" = "$latest_asset" ]]; then
                echo "Version status: ✓ Latest version installed: $latest_asset ($latest_tag - $latest_name)"
            else
                echo "Version status: ⚠ A new version is available: $latest_asset ($latest_tag - $latest_name)"
                [[ "$FAIL_IF_LATEST_NOT_INSTALLED" = true ]] && exit_code=2
            fi
        else
            echo "Version status: ✗ A new version is available: $latest_asset ($latest_tag - $latest_name)"
            [[ "$FAIL_IF_LATEST_NOT_INSTALLED" = true ]] && exit_code=1
        fi
    else
        if [[ "$FAIL_IF_LATEST_NOT_INSTALLED" = true ]]; then
            echo "Version status: ⚠ Could not retrieve latest release information"
            exit_code=3
        else
            echo "Version status: ? Could not retrieve latest release information"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "Service status: ✓ Running"
        elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
            echo "Service status: ⚠ Installed but not running"
        else
            echo "Service status: ✗ Not installed"
        fi
    else
        echo "Service status: ? (systemctl not available)"
    fi

    exit $exit_code
}

execute_command() {
    check_required_tools
    case "$COMMAND" in
        help)    show_help ;;
        version) show_version ;;
        release)
            case "$SUBCOMMAND" in
                list)    list_releases ;;
                install) install_release ;;
                *)       die "unknown release subcommand: $SUBCOMMAND" ;;
            esac
            ;;
        status)  show_status ;;
        *)       die "unknown command: $COMMAND" ;;
    esac
}

main() {
    parse_cli_arguments "$@"
    scope_check
    execute_command
}

main "$@"

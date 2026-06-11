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
# shellcheck source=lib/notify.sh
source "$BEBOP_TOOLING_LIB_DIR/notify.sh"
# shellcheck source=lib/release.sh
source "$BEBOP_TOOLING_LIB_DIR/release.sh"

# GitHub repository for be-BOP releases
readonly BEBOP_GITHUB_REPO="${BEBOP_GITHUB_REPO:-be-BOP-io-SA/be-BOP}"

# Secrets file (Zulip + SMTP credentials for notifications).
readonly SECRETS_FILE="${SECRETS_FILE:-/etc/be-BOP-tooling/secrets.env}"

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

# resolve_branch_artifact <branch_name> <artifact_name>
# Walks the latest successful workflow runs on <branch_name> and prints
# "<run_id>\t<head_sha>\t<artifact_id>" for the first run that uploaded
# an artifact named <artifact_name>. Dies if none is found.
# Requires BEBOP_GITHUB_PAT (Actions:read + Contents:read on the repo).
resolve_branch_artifact() {
    local branch="$1" want_name="$2"
    if [[ -z "${BEBOP_GITHUB_PAT:-}" ]]; then
        die "branch deploys require BEBOP_GITHUB_PAT in ${SECRETS_FILE} (fine-grained PAT, Actions:read + Contents:read on ${BEBOP_GITHUB_REPO})"
    fi
    local gh_curl=(
        --silent --show-error --fail --location
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_DOWNLOAD_TIMEOUT"
        -H "Authorization: Bearer ${BEBOP_GITHUB_PAT}"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    local runs_json
    runs_json=$(curl "${gh_curl[@]}" \
        "https://api.github.com/repos/${BEBOP_GITHUB_REPO}/actions/runs?branch=${branch}&status=success&per_page=10") \
        || die "GitHub API: failed to list workflow runs on '${branch}'"
    local runs_count
    runs_count=$(echo "$runs_json" | jq '.workflow_runs | length')
    if (( runs_count == 0 )); then
        die "no successful workflow run found on branch '${branch}' (CI rouge ? branche jamais poussée ?)"
    fi
    local i rid rsha aid
    for ((i=0; i<runs_count; i++)); do
        rid=$(echo "$runs_json" | jq -r ".workflow_runs[$i].id")
        rsha=$(echo "$runs_json" | jq -r ".workflow_runs[$i].head_sha")
        aid=$(curl "${gh_curl[@]}" \
            "https://api.github.com/repos/${BEBOP_GITHUB_REPO}/actions/runs/${rid}/artifacts" \
            | jq -r --arg n "$want_name" '.artifacts[] | select(.name == $n) | .id' | head -1)
        if [[ -n "$aid" ]]; then
            printf '%s\t%s\t%s\n' "$rid" "$rsha" "$aid"
            return 0
        fi
    done
    die "no '${want_name}' artifact found in the ${runs_count} latest successful runs on '${branch}' (artifact expired, wrong name, or workflow doesn't upload it)"
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

    # Load notification credentials (Zulip + SMTP) + BEBOP_GITHUB_PAT (used
    # by resolve_branch_artifact and by lib/release.sh's cache layer when
    # downloading branch artifacts from api.github.com).
    if [[ -f "$SECRETS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SECRETS_FILE"
    else
        log_warn "secrets file ${SECRETS_FILE} missing; notifications will be skipped"
    fi

    local tenant_domain
    tenant_domain="$(registry_get_field "$TENANT_ID" domain)"

    # Resolve the (target_name, download_url) pair. target_name keys the
    # host-wide release cache (/var/lib/be-BOP-releases-cache/<name>/).
    local target_name target_url version_for_message
    case "$target_version" in
      ""|latest)
        target_name=$(release_resolve_version "latest")
        version_for_message="$target_name"
        # URL is fetched lazily by release_cache_ensure if cache misses.
        target_url=""
        ;;
      branch=*)
        # Branch deploys go through the GitHub Actions API (artifact.ci has
        # no programmatic surface). Walk the latest successful runs and pick
        # the artifact named BEBOP_BRANCH_ARTIFACT_NAME (default
        # "be-BOP-release"). The cache is keyed by "<branch>.<sha8>" so each
        # SHA gets its own entry; re-deploys after a new push install fresh.
        local branch_name="${target_version#branch=}"
        local artifact_name="${BEBOP_BRANCH_ARTIFACT_NAME:-be-BOP-release}"
        log_info "resolving CI artifact for branch '${branch_name}' (artifact: ${artifact_name})..."
        local resolved run_id head_sha artifact_id
        resolved=$(resolve_branch_artifact "$branch_name" "$artifact_name")
        run_id=$(echo "$resolved" | cut -f1)
        head_sha=$(echo "$resolved" | cut -f2)
        artifact_id=$(echo "$resolved" | cut -f3)
        log_info "run=${run_id} sha=${head_sha:0:8} artifact_id=${artifact_id}"
        target_name="${branch_name//\//__}.${head_sha:0:8}"
        target_url="https://api.github.com/repos/${BEBOP_GITHUB_REPO}/actions/artifacts/${artifact_id}/zip"
        version_for_message="branch ${branch_name} (${head_sha:0:8})"
        ;;
      *)
        target_name="$target_version"
        version_for_message="$target_version"
        target_url=""
        ;;
    esac

    # ERR-trap operator notification past this point.
    # shellcheck disable=SC2064
    trap "on_install_failure '${TENANT_ID}' '${version_for_message}' \$?" ERR

    # Populate the host cache if needed (no-op if another tenant already
    # installed this exact release; flock-protected against concurrent calls).
    if [[ -n "$target_url" ]]; then
        # Branch path: URL pre-computed, skip release_get_asset_url.
        release_cache_ensure_from_url "$target_name" "$target_url"
    else
        # Tag/latest path: release_cache_ensure fetches the asset URL only if
        # the cache misses, then downloads.
        release_cache_ensure "$target_name"
    fi

    # Tenant-side atomic symlink swap into the cache + service restart.
    release_cache_set_current "$TENANT_ID" "$target_name"

    local service="bebop@${TENANT_ID}.service"
    if [[ "$NO_RESTART_AFTER_INSTALL" = false ]]; then
        if run_privileged systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "restarting ${service}..."
            run_privileged systemctl restart "$service" \
                || log_warn "failed to restart ${service}; restart manually if needed"
        elif run_privileged systemctl is-enabled --quiet "$service" 2>/dev/null; then
            log_info "starting ${service}..."
            run_privileged systemctl start "$service" \
                || log_warn "failed to start ${service}; start manually if needed"
        else
            log_debug "${service} not configured; skipping restart"
        fi
    else
        log_info "skipping ${service} restart (--no-restart-after-install)"
    fi

    trap - ERR
    notify_success \
        "[be-BOP tooling] tenant-cli install ${TENANT_ID} OK" \
        "Tenant ${TENANT_ID} switched to be-BOP ${version_for_message} at https://${tenant_domain}/."
}

# on_install_failure: ERR trap helper called from install_release.
# Sends an operator alert (Zulip + SMTP) and lets the exit propagate.
on_install_failure() {
    local tenant="$1" version="$2" rc="$3"
    log_error "tenant-cli install failed (tenant=${tenant}, target=${version}, rc=${rc})"
    notify_failure \
        "[be-BOP tooling] tenant-cli install ${tenant} FAILED" \
        "$(printf 'Tenant: %s\nTarget: %s\nExit code: %s\n\nSee journalctl -t %s --since "1 hour ago" for the full log.\n' \
            "$tenant" "$version" "$rc" "$BEBOP_TOOLING_SYSLOG_IDENT")" \
        || true
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
        local current_target
        current_target=$(readlink -f "$current_link")
        current_installed=$(basename "$current_target")
        echo "Installed release: $current_installed"
        # Marker lives next to the release files — whether they're in the
        # host cache (new layout) or in the per-tenant releases dir (legacy).
        if [[ -f "$current_target/.bebop_install_success" ]]; then
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
    # `release install` needs to source /etc/be-BOP-tooling/secrets.env (0600,
    # root-only) for notification credentials. Re-exec under sudo so the rest
    # of the install path runs as root throughout — matches add-tenant.sh UX
    # and removes the need to sluice secrets through run_privileged.
    # Other commands (list / status / help / version) stay caller-owned.
    if [[ "$COMMAND" == "release" && "$SUBCOMMAND" == "install" && $EUID -ne 0 ]]; then
        log_info "elevating to root for install (sudo)..."
        exec sudo -E -- "$0" "$@"
    fi
    scope_check
    execute_command
}

main "$@"

# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 be-bop.io contributors
#
# release.sh — host-shared release cache + per-tenant activation.
#
# A "release" is one of:
#   - a published GitHub release tag, whose asset matches
#       be-BOP\.release\.YYYY-MM-DD\.<sha>(.*)?\.zip
#   - a CI artifact from be-BOP-io-SA/be-BOP for a feature branch
#     (keyed by tenant-cli.sh as "<branch>.<sha8>" — opaque to this lib).
#
# Architecture: each release is downloaded, extracted, and `pnpm install`-ed
# EXACTLY ONCE per host, under $BEBOP_RELEASE_CACHE_ROOT/<name>/. Per-tenant
# activation = an atomic symlink swap of /var/lib/be-BOP/<tenant>/releases/current
# pointing into the cache. Result: N tenants on the same release = 1 download,
# 1 install, 1 disk arborescence.
#
# Concurrency: release_cache_ensure_from_url holds a flock(2) on a
# per-name lock file so concurrent installs of the same release (e.g.
# upgrade-all.sh --parallel) collapse to one.
#
# Source AFTER lib/log.sh and lib/sudo.sh.
# Requires: curl, jq, unzip, pnpm, flock.

[[ -n "${_BEBOP_RELEASE_SOURCED:-}" ]] && return 0
readonly _BEBOP_RELEASE_SOURCED=1

: "${BEBOP_GITHUB_REPO:=be-BOP-io-SA/be-BOP}"
: "${BEBOP_RELEASE_CACHE_ROOT:=/var/lib/be-BOP-releases-cache}"
readonly _BEBOP_RELEASE_ASSET_RE='^be-BOP\.release\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.[a-f0-9]+.*\.zip$'

# _release_gh_get <url>
# GET a GitHub API URL and print the body on HTTP 2xx. Auto-attaches
# BEBOP_GITHUB_PAT if set. Inspects the HTTP status code so the error
# message tells the operator what actually happened — the old `curl --fail`
# approach treated every 4xx as "tag not found", which made rate-limit
# failures (403) impossible to diagnose from the notification alone.
_release_gh_get() {
    local url="$1" tmp http_code body
    local hdr=(
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    if [[ -n "${BEBOP_GITHUB_PAT:-}" ]]; then
        hdr+=(-H "Authorization: Bearer ${BEBOP_GITHUB_PAT}")
    fi
    tmp=$(mktemp)
    http_code=$(curl -sS --max-time 30 \
        -o "$tmp" -w '%{http_code}' \
        "${hdr[@]}" \
        "$url" 2>/dev/null || true)
    body=$(cat "$tmp")
    rm -f "$tmp"
    case "$http_code" in
        2*)
            printf '%s' "$body"
            return 0
            ;;
        401)
            die "GitHub API ${url}: HTTP 401 — BEBOP_GITHUB_PAT invalid, revoked, or expired"
            ;;
        403)
            if [[ -z "${BEBOP_GITHUB_PAT:-}" ]]; then
                die "GitHub API ${url}: HTTP 403 — rate-limited (unauthenticated quota is 60 req/h). Set BEBOP_GITHUB_PAT in /etc/be-BOP-tooling/secrets.env (Actions:read + Contents:read on ${BEBOP_GITHUB_REPO})."
            else
                die "GitHub API ${url}: HTTP 403 — rate-limited OR PAT missing required scopes (Actions:read + Contents:read on ${BEBOP_GITHUB_REPO})"
            fi
            ;;
        404)
            die "GitHub API ${url}: HTTP 404 — resource does not exist"
            ;;
        000)
            die "GitHub API ${url}: connection failed (no HTTP response — DNS / network / TLS issue)"
            ;;
        *)
            die "GitHub API ${url}: HTTP ${http_code}"
            ;;
    esac
}

# release_resolve_version <version_arg>
# - "latest" → most recent release tag with a matching asset
# - any other string is taken as a concrete tag and validated to exist
# Outputs the resolved tag on stdout.
release_resolve_version() {
    local arg="$1"
    if [[ "$arg" != "latest" && -n "$arg" ]]; then
        _release_gh_get "https://api.github.com/repos/${BEBOP_GITHUB_REPO}/releases/tags/${arg}" >/dev/null
        printf '%s\n' "$arg"
        return 0
    fi
    local resp
    resp=$(_release_gh_get "https://api.github.com/repos/${BEBOP_GITHUB_REPO}/releases?per_page=20")
    local tag
    tag=$(printf '%s' "$resp" \
        | jq -r --arg re "$_BEBOP_RELEASE_ASSET_RE" \
            '[.[] | select(.assets[]?.name | test($re))] | .[0].tag_name // empty')
    if [[ -z "$tag" ]]; then
        die "release_resolve_version: no release with a matching be-BOP asset found"
    fi
    printf '%s\n' "$tag"
}

# release_get_asset_url <tag>
# Outputs the browser_download_url for the be-BOP zip asset of <tag>.
release_get_asset_url() {
    local tag="$1"
    local resp
    resp=$(_release_gh_get "https://api.github.com/repos/${BEBOP_GITHUB_REPO}/releases/tags/${tag}")
    local url
    url=$(printf '%s' "$resp" \
        | jq -r --arg re "$_BEBOP_RELEASE_ASSET_RE" \
            '.assets[] | select(.name | test($re)) | .browser_download_url' \
        | head -1)
    if [[ -z "$url" ]]; then
        die "release_get_asset_url: no matching asset on release ${tag}"
    fi
    printf '%s\n' "$url"
}

# release_cache_dir <name>
# Path of the cache entry for <name> (whether it exists or not).
release_cache_dir() {
    printf '%s/%s' "$BEBOP_RELEASE_CACHE_ROOT" "$1"
}

# release_cache_has <name>
# Returns 0 iff the cache entry exists AND is fully installed (marker present).
release_cache_has() {
    local cache_dir
    cache_dir=$(release_cache_dir "$1")
    run_privileged test -f "${cache_dir}/.bebop_install_success"
}

# _release_cache_locate_payload <extract_root>
# Echo the directory containing package.json. Handles three zip layouts:
#  1. GitHub release zip → 'be-BOP release X.Y.Z/' top-level dir.
#  2. Actions artifact (flat) → package.json at extract_root.
#  3. Actions artifact (zip-of-zip) → an inner *.zip to unwrap first; the
#     caller passes the already-unwrapped root in that case.
_release_cache_locate_payload() {
    find "$1" -name "package.json" -type f -printf '%h\n' 2>/dev/null | head -1
}

# release_cache_ensure_from_url <name> <download_url>
# Idempotent: if cache has <name>/.bebop_install_success, no-op. Otherwise
# downloads + extracts + pnpm-installs under $BEBOP_RELEASE_CACHE_ROOT/<name>.
# Concurrent calls for the same <name> are serialised by an flock(2) on a
# sibling lock file — only one actually downloads, the others observe the
# marker on lock release and short-circuit.
release_cache_ensure_from_url() {
    local name="$1" url="$2"
    if release_cache_has "$name"; then
        log_debug "cache: ${name} already present at $(release_cache_dir "$name")"
        return 0
    fi
    run_privileged install -d -m 0755 "$BEBOP_RELEASE_CACHE_ROOT"
    local lock="${BEBOP_RELEASE_CACHE_ROOT}/.${name//\//__}.lock"
    run_privileged touch "$lock"
    run_privileged chmod 0644 "$lock"

    # Subshell holds the lock; export everything we need.
    (
        exec 9<>"$lock" || die "release_cache: cannot open lock ${lock}"
        flock -x 9 || die "release_cache: failed to acquire lock ${lock}"
        # Re-check inside the lock — another caller may have populated it.
        if release_cache_has "$name"; then
            log_debug "cache: ${name} populated by concurrent caller while waiting on lock"
            exit 0
        fi
        local cache_dir
        cache_dir=$(release_cache_dir "$name")
        log_info "cache: downloading ${name}..."
        local tmp
        tmp=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf '$tmp'" EXIT
        # Auto-attach GitHub PAT when the download URL is the Actions
        # artifacts API endpoint (branch deploys). Tag/release downloads
        # hit the public github.com release CDN and don't need auth.
        local download_headers=()
        if [[ "$url" == https://api.github.com/* && -n "${BEBOP_GITHUB_PAT:-}" ]]; then
            download_headers+=(
                -H "Authorization: Bearer ${BEBOP_GITHUB_PAT}"
                -H "Accept: application/vnd.github+json"
                -H "X-GitHub-Api-Version: 2022-11-28"
            )
        fi
        if ! curl -fsSL "${download_headers[@]+"${download_headers[@]}"}" \
                --connect-timeout 10 --max-time 600 \
                -o "${tmp}/release.zip" "$url"; then
            die "cache: download failed for ${name}"
        fi
        local extract_root="${tmp}/extracted"
        mkdir -p "$extract_root"
        if ! ( cd "$extract_root" && unzip -q "${tmp}/release.zip" ); then
            die "cache: unzip failed for ${name}"
        fi
        local payload_dir
        payload_dir=$(_release_cache_locate_payload "$extract_root")
        if [[ -z "$payload_dir" ]]; then
            # Actions-artifact zip-of-zip case: one inner .zip, unwrap it.
            local inner_zip
            inner_zip=$(find "$extract_root" -mindepth 1 -maxdepth 2 -name "*.zip" -type f | head -1)
            if [[ -n "$inner_zip" ]]; then
                local inner_root="${tmp}/inner"
                mkdir -p "$inner_root"
                ( cd "$inner_root" && unzip -q "$inner_zip" ) \
                    || die "cache: failed to extract inner zip for ${name}"
                payload_dir=$(_release_cache_locate_payload "$inner_root")
            fi
        fi
        [[ -n "$payload_dir" ]] || die "cache: could not locate package.json in ${name} archive"

        # Stage into a sibling temp dir, install deps, then atomic rename.
        # Tag names like "rel/2026-05-25/1c57ad3" contain slashes → cache_dir
        # is nested ("releases-cache/rel/2026-05-25/1c57ad3"). `install -d`
        # creates all missing intermediate components in one go.
        local staging="${cache_dir}.staging.$$"
        run_privileged install -d -m 0755 "$(dirname "$cache_dir")"
        run_privileged rm -rf "$staging" "$cache_dir"
        run_privileged mv "$payload_dir" "$staging"
        run_privileged chown -R root:root "$staging"
        run_privileged find "$staging" -type d -exec chmod 0755 {} +
        run_privileged find "$staging" -type f -exec chmod 0644 {} +
        log_info "cache: installing deps for ${name}..."
        if ! ( cd "$staging" && run_privileged env \
                HOME=/tmp COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
                pnpm install --prod --frozen-lockfile ); then
            run_privileged rm -rf "$staging"
            die "cache: pnpm install failed for ${name}"
        fi
        run_privileged touch "${staging}/.bebop_install_success"
        run_privileged mv -T "$staging" "$cache_dir"
        log_info "cache: ${name} ready at ${cache_dir}"
    ) || return $?
}

# release_cache_ensure <tag>
# Tag-flow helper: no-op on cache hit (zero API calls), otherwise fetch the
# asset URL from GitHub and populate the cache. Use this for tag/release-based
# installs; branch-based installs from tenant-cli use ensure_from_url directly
# with a URL they computed via the Actions API.
release_cache_ensure() {
    local tag="$1"
    if release_cache_has "$tag"; then
        log_debug "cache: ${tag} already present; no API call needed"
        return 0
    fi
    local url
    url=$(release_get_asset_url "$tag")
    release_cache_ensure_from_url "$tag" "$url"
}

# release_cache_set_current <tenant> <name>
# Atomically swap /var/lib/be-BOP/<tenant>/releases/current to point to the
# cache entry for <name>. Caller must have ensured the entry exists.
release_cache_set_current() {
    local tenant="$1" name="$2"
    local cache_dir
    cache_dir=$(release_cache_dir "$name")
    run_privileged test -d "$cache_dir" \
        || die "release_cache_set_current: cache entry ${name} not present at ${cache_dir}"
    local releases_dir="/var/lib/be-BOP/${tenant}/releases"
    run_privileged install -d -m 0755 "$releases_dir"
    local link="${releases_dir}/current"
    local tmp_link="${releases_dir}/.current.$$"
    run_privileged ln -sfn "$cache_dir" "$tmp_link"
    run_privileged mv -T "$tmp_link" "$link"
    log_info "release: ${tenant}/current → ${name}"
}

# release_get_current_tag <tenant>
# Returns the basename of whatever <tenant>/releases/current points to.
# Works transparently for legacy relative symlinks (basename = old tag) and
# new absolute cache symlinks (basename = cache name).
release_get_current_tag() {
    local tenant="$1"
    local link="/var/lib/be-BOP/${tenant}/releases/current"
    if [[ -L "$link" ]]; then
        basename "$(readlink -f "$link")"
    fi
}

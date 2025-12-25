#!/usr/bin/env bash
#
# Plugin Manager for F5 Distributed Cloud Marketplace
# Registry-based plugin installation with GitHub and npm support
#
# Usage:
#   ./scripts/plugin-manager.sh install <plugin-name> [version]
#   ./scripts/plugin-manager.sh update <plugin-name>
#   ./scripts/plugin-manager.sh list
#   ./scripts/plugin-manager.sh sync
#   ./scripts/plugin-manager.sh npm-info <plugin-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGINS_JSON="$MARKETPLACE_ROOT/plugins.json"
PLUGINS_DIR="$MARKETPLACE_ROOT/plugins"
CACHE_DIR="${CLAUDE_PLUGINS_CACHE:-$HOME/.claude/plugins/cache}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# Check dependencies
check_deps() {
    for cmd in curl jq tar; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
}

# Get plugin info from registry
get_plugin_info() {
    local plugin_name="$1"
    local field="$2"
    jq -r ".plugins[\"$plugin_name\"].$field // empty" "$PLUGINS_JSON"
}

# Get version info
get_version_info() {
    local plugin_name="$1"
    local version="$2"
    local field="$3"
    jq -r ".plugins[\"$plugin_name\"].versions[\"$version\"].$field // empty" "$PLUGINS_JSON"
}

# Detect source type for a plugin (github or npm)
get_source_type() {
    local plugin_name="$1"
    local source=$(jq -r ".plugins[\"$plugin_name\"].source // \"github\"" "$PLUGINS_JSON")
    echo "$source"
}

# Get npm-specific config
get_npm_info() {
    local plugin_name="$1"
    local field="$2"
    jq -r ".plugins[\"$plugin_name\"].npm.$field // empty" "$PLUGINS_JSON"
}

# URL encode a string (for scoped packages like @org/package)
url_encode() {
    local string="$1"
    printf '%s' "$string" | sed 's/@/%40/g; s/\//%2F/g'
}

# Fetch npm package metadata from registry
fetch_npm_metadata() {
    local package_name="$1"
    local registry="${2:-https://registry.npmjs.org}"
    local encoded_package=$(url_encode "$package_name")
    local auth_header=""

    # Support NPM_TOKEN for private packages
    if [[ -n "${NPM_TOKEN:-}" ]]; then
        curl -sL -H "Authorization: Bearer $NPM_TOKEN" "$registry/$encoded_package"
    else
        curl -sL "$registry/$encoded_package"
    fi
}

# Get latest version from npm registry
get_npm_latest_version() {
    local package_name="$1"
    local registry="${2:-https://registry.npmjs.org}"
    local metadata=$(fetch_npm_metadata "$package_name" "$registry")
    echo "$metadata" | jq -r '.["dist-tags"].latest // empty'
}

# Get tarball URL from npm registry for a specific version
get_npm_tarball_url() {
    local package_name="$1"
    local version="$2"
    local registry="${3:-https://registry.npmjs.org}"
    local metadata=$(fetch_npm_metadata "$package_name" "$registry")
    echo "$metadata" | jq -r ".versions[\"$version\"].dist.tarball // empty"
}

# Get integrity hash from npm registry
get_npm_integrity() {
    local package_name="$1"
    local version="$2"
    local registry="${3:-https://registry.npmjs.org}"
    local metadata=$(fetch_npm_metadata "$package_name" "$registry")
    echo "$metadata" | jq -r ".versions[\"$version\"].dist.integrity // empty"
}

# List all available plugins
cmd_list() {
    log_info "Available plugins in registry:"
    echo ""
    jq -r '.plugins | to_entries[] | "\(.key)\t\(.value.source // "github")\t\(.value.latest)\t\(.value.description)"' "$PLUGINS_JSON" | \
        while IFS=$'\t' read -r name source version desc; do
            printf "  ${GREEN}%-20s${NC} ${BLUE}%-8s${NC} ${YELLOW}v%-10s${NC} %s\n" "$name" "[$source]" "$version" "$desc"
        done
    echo ""

    # Show installed plugins
    if [[ -d "$PLUGINS_DIR" ]]; then
        log_info "Installed plugins:"
        for plugin_dir in "$PLUGINS_DIR"/*/; do
            if [[ -d "$plugin_dir" ]]; then
                local name=$(basename "$plugin_dir")
                local version_file="$plugin_dir/.version"
                local version="unknown"
                [[ -f "$version_file" ]] && version=$(cat "$version_file")
                printf "  ${GREEN}%-20s${NC} ${YELLOW}v%-10s${NC}\n" "$name" "$version"
            fi
        done
    fi
}

# Install from GitHub tarball
install_from_github() {
    local plugin_name="$1"
    local version="$2"

    local tarball_url=$(get_version_info "$plugin_name" "$version" "tarball")
    if [[ -z "$tarball_url" ]]; then
        log_error "Version not found: $plugin_name@$version"
        exit 1
    fi

    local plugin_dir="$PLUGINS_DIR/$plugin_name"
    local cache_plugin_dir="$CACHE_DIR/f5-distributed-cloud/$plugin_name/$version"

    log_info "Installing $plugin_name@$version from GitHub..."

    # Create temp directory
    local tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    # Download tarball
    log_info "Downloading from $tarball_url"
    curl -sL "$tarball_url" -o "$tmp_dir/plugin.tar.gz"

    # Verify SHA256 if available
    local expected_sha256=$(get_version_info "$plugin_name" "$version" "sha256")
    if [[ -n "$expected_sha256" ]]; then
        log_info "Verifying checksum..."
        local actual_sha256=$(shasum -a 256 "$tmp_dir/plugin.tar.gz" | cut -d' ' -f1)
        if [[ "$actual_sha256" != "$expected_sha256" ]]; then
            log_error "Checksum verification failed!"
            exit 1
        fi
        log_success "Checksum verified"
    fi

    # Extract
    log_info "Extracting..."
    tar -xzf "$tmp_dir/plugin.tar.gz" -C "$tmp_dir"

    # Find extracted directory (GitHub adds repo-version prefix)
    local extracted_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)

    # Remove old installation
    [[ -d "$plugin_dir" ]] && rm -rf "$plugin_dir"

    # Move to plugins directory
    mkdir -p "$PLUGINS_DIR"
    mv "$extracted_dir" "$plugin_dir"

    # Write version file
    echo "$version" > "$plugin_dir/.version"

    # Also update cache for Claude Code
    mkdir -p "$cache_plugin_dir"
    cp -r "$plugin_dir/"* "$cache_plugin_dir/"

    log_success "Installed $plugin_name@$version to $plugin_dir"
    log_success "Cached at $cache_plugin_dir"
}

# Install from npm registry
install_from_npm() {
    local plugin_name="$1"
    local version="$2"
    local package_name=$(get_npm_info "$plugin_name" "package")
    local registry=$(get_npm_info "$plugin_name" "registry")
    registry="${registry:-https://registry.npmjs.org}"

    local tarball_url=$(get_version_info "$plugin_name" "$version" "tarball")

    # If tarball not in plugins.json, fetch from npm registry
    if [[ -z "$tarball_url" ]]; then
        log_info "Fetching tarball URL from npm registry..."
        tarball_url=$(get_npm_tarball_url "$package_name" "$version" "$registry")
    fi

    if [[ -z "$tarball_url" ]]; then
        log_error "Could not find tarball for $package_name@$version"
        exit 1
    fi

    local plugin_dir="$PLUGINS_DIR/$plugin_name"
    local cache_plugin_dir="$CACHE_DIR/f5-distributed-cloud/$plugin_name/$version"

    log_info "Installing $plugin_name@$version from npm..."

    # Create temp directory
    local tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    # Download tarball (with auth if NPM_TOKEN is set)
    log_info "Downloading from $tarball_url"
    if [[ -n "${NPM_TOKEN:-}" ]]; then
        curl -sL -H "Authorization: Bearer $NPM_TOKEN" "$tarball_url" -o "$tmp_dir/plugin.tgz"
    else
        curl -sL "$tarball_url" -o "$tmp_dir/plugin.tgz"
    fi

    # Verify integrity if available
    local expected_integrity=$(get_version_info "$plugin_name" "$version" "integrity")
    if [[ -n "$expected_integrity" ]]; then
        log_info "Verifying package integrity..."
        local actual_hash=$(openssl dgst -sha512 -binary "$tmp_dir/plugin.tgz" | base64 | tr -d '\n')
        local expected_hash="${expected_integrity#sha512-}"
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            log_error "Integrity check failed!"
            log_error "Expected: $expected_hash"
            log_error "Actual: $actual_hash"
            exit 1
        fi
        log_success "Integrity verified"
    fi

    # Extract (npm tarballs have 'package/' prefix)
    log_info "Extracting..."
    mkdir -p "$tmp_dir/extracted"
    tar -xzf "$tmp_dir/plugin.tgz" -C "$tmp_dir/extracted"

    # npm tarballs extract to 'package/' directory
    local extracted_dir="$tmp_dir/extracted/package"
    if [[ ! -d "$extracted_dir" ]]; then
        # Fallback: find first directory
        extracted_dir=$(find "$tmp_dir/extracted" -mindepth 1 -maxdepth 1 -type d | head -1)
    fi

    # Remove old installation
    [[ -d "$plugin_dir" ]] && rm -rf "$plugin_dir"

    # Move to plugins directory
    mkdir -p "$PLUGINS_DIR"
    mv "$extracted_dir" "$plugin_dir"

    # Write version file
    echo "$version" > "$plugin_dir/.version"

    # Also update cache for Claude Code
    mkdir -p "$cache_plugin_dir"
    cp -r "$plugin_dir/"* "$cache_plugin_dir/"

    log_success "Installed $plugin_name@$version to $plugin_dir"
    log_success "Cached at $cache_plugin_dir"
}

# Install a plugin (routes to appropriate source)
cmd_install() {
    local plugin_name="$1"
    local version="${2:-$(get_plugin_info "$plugin_name" "latest")}"

    if [[ -z "$version" ]]; then
        log_error "Plugin not found: $plugin_name"
        exit 1
    fi

    local source_type=$(get_source_type "$plugin_name")

    case "$source_type" in
        npm)
            install_from_npm "$plugin_name" "$version"
            ;;
        github|*)
            install_from_github "$plugin_name" "$version"
            ;;
    esac
}

# Update a plugin to latest
cmd_update() {
    local plugin_name="$1"
    local latest=$(get_plugin_info "$plugin_name" "latest")

    if [[ -z "$latest" ]]; then
        log_error "Plugin not found: $plugin_name"
        exit 1
    fi

    local current="unknown"
    local version_file="$PLUGINS_DIR/$plugin_name/.version"
    [[ -f "$version_file" ]] && current=$(cat "$version_file")

    if [[ "$current" == "$latest" ]]; then
        log_info "$plugin_name is already at latest version ($latest)"
        return 0
    fi

    log_info "Updating $plugin_name from $current to $latest"
    cmd_install "$plugin_name" "$latest"
}

# Sync all plugins to their latest versions
cmd_sync() {
    log_info "Syncing all plugins to latest versions..."

    local plugins=$(jq -r '.plugins | keys[]' "$PLUGINS_JSON")

    for plugin in $plugins; do
        cmd_update "$plugin"
    done

    log_success "All plugins synced"
}

# Show npm package info from registry
cmd_npm_info() {
    local plugin_name="$1"

    local source_type=$(get_source_type "$plugin_name")
    if [[ "$source_type" != "npm" ]]; then
        log_error "$plugin_name is not an npm package (source: $source_type)"
        exit 1
    fi

    local package_name=$(get_npm_info "$plugin_name" "package")
    local registry=$(get_npm_info "$plugin_name" "registry")
    registry="${registry:-https://registry.npmjs.org}"

    log_info "Fetching metadata for $package_name from $registry..."

    local metadata=$(fetch_npm_metadata "$package_name" "$registry")

    if [[ -z "$metadata" ]] || [[ "$metadata" == "null" ]]; then
        log_error "Could not fetch metadata for $package_name"
        exit 1
    fi

    local latest=$(echo "$metadata" | jq -r '.["dist-tags"].latest // empty')
    local tarball=$(echo "$metadata" | jq -r ".versions[\"$latest\"].dist.tarball // empty")
    local integrity=$(echo "$metadata" | jq -r ".versions[\"$latest\"].dist.integrity // empty")
    local released=$(echo "$metadata" | jq -r ".time[\"$latest\"] // empty" | cut -dT -f1)

    echo ""
    log_success "Package: $package_name"
    log_success "Latest version: $latest"
    log_info "Tarball: $tarball"
    log_info "Integrity: $integrity"
    log_info "Released: $released"
    echo ""
    log_info "Available versions:"
    echo "$metadata" | jq -r '.versions | keys | reverse | .[:10][]' | while read -r ver; do
        printf "  - %s\n" "$ver"
    done
    echo ""
    log_info "Add to plugins.json versions:"
    echo ""
    cat << EOF
"$latest": {
  "tarball": "$tarball",
  "integrity": "$integrity",
  "released": "$released",
  "changelog": "https://github.com/robinmordasiewicz/f5xc-console/releases/tag/v$latest"
}
EOF
}

# Update Claude Code installed_plugins.json
update_claude_registry() {
    local plugin_name="$1"
    local version="$2"
    local install_path="$3"
    local claude_plugins="$HOME/.claude/plugins/installed_plugins.json"

    if [[ ! -f "$claude_plugins" ]]; then
        log_warn "Claude plugins registry not found at $claude_plugins"
        return 0
    fi

    local registry_name="${plugin_name}@f5-distributed-cloud"
    local plugin_json_name=$(jq -r '.name // empty' "$install_path/.claude-plugin/plugin.json" 2>/dev/null || echo "$plugin_name")

    # Update the registry entry
    local tmp_file=$(mktemp)
    jq --arg name "$registry_name" \
       --arg path "$install_path" \
       --arg version "$version" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
       '.plugins[$name] = [{
         "scope": "user",
         "installPath": $path,
         "version": $version,
         "installedAt": .plugins[$name][0].installedAt // $now,
         "lastUpdated": $now,
         "isLocal": true
       }]' "$claude_plugins" > "$tmp_file"

    mv "$tmp_file" "$claude_plugins"
    log_success "Updated Claude registry for $plugin_name"
}

# Main
main() {
    check_deps

    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        install)
            [[ $# -lt 1 ]] && { log_error "Usage: $0 install <plugin-name> [version]"; exit 1; }
            cmd_install "$@"
            ;;
        update)
            [[ $# -lt 1 ]] && { log_error "Usage: $0 update <plugin-name>"; exit 1; }
            cmd_update "$@"
            ;;
        list)
            cmd_list
            ;;
        sync)
            cmd_sync
            ;;
        npm-info)
            [[ $# -lt 1 ]] && { log_error "Usage: $0 npm-info <plugin-name>"; exit 1; }
            cmd_npm_info "$@"
            ;;
        help|--help|-h)
            echo "Plugin Manager for F5 Distributed Cloud Marketplace"
            echo ""
            echo "Usage:"
            echo "  $0 install <plugin-name> [version]  Install a plugin"
            echo "  $0 update <plugin-name>             Update plugin to latest"
            echo "  $0 list                             List available/installed plugins"
            echo "  $0 sync                             Sync all plugins to latest"
            echo "  $0 npm-info <plugin-name>           Show npm package info"
            echo ""
            echo "Environment variables:"
            echo "  NPM_TOKEN                           Bearer token for private npm packages"
            echo "  CLAUDE_PLUGINS_CACHE               Custom cache directory (default: ~/.claude/plugins/cache)"
            echo ""
            ;;
        *)
            log_error "Unknown command: $cmd"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
}

main "$@"

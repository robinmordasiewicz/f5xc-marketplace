#!/usr/bin/env bash
# Copyright (c) 2026 Robin Mordasiewicz. MIT License.

#
# Sync plugins from npm registry
# Updates plugins.json and marketplace.json with latest versions
#
# Environment variables:
#   NPM_TOKEN         - Bearer token for private npm packages (optional)
#   DISPATCH_PLUGIN   - Specific plugin from webhook dispatch (optional)
#   DISPATCH_VERSION  - Specific version from webhook dispatch (optional)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGINS_JSON="$MARKETPLACE_ROOT/plugins.json"
MARKETPLACE_JSON="$MARKETPLACE_ROOT/.claude-plugin/marketplace.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# URL encode for scoped packages
url_encode() {
    local string="$1"
    printf '%s' "$string" | sed 's/@/%40/g; s/\//%2F/g'
}

# Fetch npm package metadata
fetch_npm_metadata() {
    local package_name="$1"
    local registry="${2:-https://registry.npmjs.org}"
    local encoded_package=$(url_encode "$package_name")

    if [[ -n "${NPM_TOKEN:-}" ]]; then
        curl -sL -H "Authorization: Bearer $NPM_TOKEN" "$registry/$encoded_package"
    else
        curl -sL "$registry/$encoded_package"
    fi
}

# Sync a single npm plugin
sync_npm_plugin() {
    local plugin_key="$1"

    # Get plugin config from plugins.json
    local source=$(jq -r ".plugins[\"$plugin_key\"].source // \"github\"" "$PLUGINS_JSON")

    if [[ "$source" != "npm" ]]; then
        log_info "Skipping $plugin_key (source: $source, not npm)"
        return 0
    fi

    local package_name=$(jq -r ".plugins[\"$plugin_key\"].npm.package" "$PLUGINS_JSON")
    local registry=$(jq -r ".plugins[\"$plugin_key\"].npm.registry // \"https://registry.npmjs.org\"" "$PLUGINS_JSON")
    local current_version=$(jq -r ".plugins[\"$plugin_key\"].latest" "$PLUGINS_JSON")

    log_info "Checking $plugin_key ($package_name)..."

    # Fetch metadata from npm
    local metadata=$(fetch_npm_metadata "$package_name" "$registry")

    if [[ -z "$metadata" ]] || [[ "$metadata" == "null" ]] || echo "$metadata" | jq -e '.error' > /dev/null 2>&1; then
        log_error "Failed to fetch metadata for $package_name"
        return 1
    fi

    # Get latest version info
    local latest_version=$(echo "$metadata" | jq -r '.["dist-tags"].latest')
    local tarball=$(echo "$metadata" | jq -r ".versions[\"$latest_version\"].dist.tarball")
    local integrity=$(echo "$metadata" | jq -r ".versions[\"$latest_version\"].dist.integrity")
    local released=$(echo "$metadata" | jq -r ".time[\"$latest_version\"]" | cut -dT -f1)

    # If dispatch provided a specific version, use that
    if [[ -n "${DISPATCH_VERSION:-}" ]] && [[ "${DISPATCH_PLUGIN:-}" == "$plugin_key" ]]; then
        latest_version="$DISPATCH_VERSION"
        tarball=$(echo "$metadata" | jq -r ".versions[\"$latest_version\"].dist.tarball")
        integrity=$(echo "$metadata" | jq -r ".versions[\"$latest_version\"].dist.integrity")
        released=$(echo "$metadata" | jq -r ".time[\"$latest_version\"]" | cut -dT -f1)
    fi

    log_info "  Current: $current_version"
    log_info "  Latest:  $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        log_success "  Already up to date"
        return 0
    fi

    log_info "  Updating to $latest_version..."

    # Get repository URL for changelog
    local repo_url=$(jq -r ".plugins[\"$plugin_key\"].repository // empty" "$PLUGINS_JSON")
    local changelog_url=""
    if [[ -n "$repo_url" ]]; then
        changelog_url="${repo_url}/releases/tag/v${latest_version}"
    fi

    # Update plugins.json - add new version entry
    local tmp_file=$(mktemp)
    jq --arg plugin "$plugin_key" \
       --arg version "$latest_version" \
       --arg tarball "$tarball" \
       --arg integrity "$integrity" \
       --arg released "$released" \
       --arg changelog "$changelog_url" \
       '.plugins[$plugin].latest = $version |
        .plugins[$plugin].versions[$version] = {
          "tarball": $tarball,
          "integrity": $integrity,
          "released": $released,
          "changelog": $changelog
        }' "$PLUGINS_JSON" > "$tmp_file"
    mv "$tmp_file" "$PLUGINS_JSON"

    # Update marketplace.json
    jq --arg plugin "$plugin_key" \
       --arg version "$latest_version" \
       --arg tarball "$tarball" \
       '(.plugins[] | select(.name == $plugin)).version = $version |
        (.plugins[] | select(.name == $plugin)).registry.tarball = $tarball' \
       "$MARKETPLACE_JSON" > "$tmp_file"
    mv "$tmp_file" "$MARKETPLACE_JSON"

    log_success "  Updated $plugin_key to $latest_version"
    return 0
}

# Main sync function
main() {
    log_info "Syncing plugins from npm registry..."
    echo ""

    # Get all plugin keys
    local plugins=$(jq -r '.plugins | keys[]' "$PLUGINS_JSON")

    local updated=0
    local failed=0

    for plugin in $plugins; do
        if sync_npm_plugin "$plugin"; then
            ((updated++)) || true
        else
            ((failed++)) || true
        fi
        echo ""
    done

    log_info "Sync complete: $updated plugins checked, $failed failed"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

main "$@"

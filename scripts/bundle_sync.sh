#!/bin/bash

# Script to update Containerfile-downstream SHA references with latest snapshot
# and create a PR against the correct branch in the forklift repo

set -e

# Source utility functions
source scripts/util.sh

# ============================================================================
# Configuration Variables (can be overridden externally)
# ============================================================================

# Base URL pattern for Containerfile-downstream
# Use {BRANCH} as a placeholder that will be replaced with the actual branch
: "${CONTAINERFILE_BASE_URL:=https://raw.githubusercontent.com/kubev2v/forklift}"
: "${CONTAINERFILE_PATH:=build/forklift-operator-bundle/Containerfile-downstream}"

# Extraction script paths
: "${LATEST_SNAPSHOT_SCRIPT:=./scripts/latest_snapshot.sh}"
: "${SNAPSHOT_CONTENT_SCRIPT:=./scripts/snapshot_content.sh}"

# ============================================================================


# Function to print usage
usage() {
    echo "Usage: $0 <version> [target_branch] [dry_run]"
    echo ""
    echo "Arguments:"
    echo "  version       - Version to get snapshot for (e.g., '2-10', 'dev-preview')"
    echo "  target_branch - Target branch for PR (default: 'main')"
    echo "  dry_run       - Set to 'true' to only show what would be changed (default: 'false')"
    echo ""
    echo "Examples:"
    echo "  $0 2-10"
    echo "  $0 dev-preview release-2.10"
    echo "  $0 2-10 main true"
    exit 1
}


# Function to get latest snapshot using existing script
get_latest_snapshot() {
    local version="$1"
    
    # Use the configured snapshot script
    local snapshot_name
    snapshot_name=$("$LATEST_SNAPSHOT_SCRIPT" "$version" 2>/dev/null)
    
    if [ -z "$snapshot_name" ]; then
        echo "ERROR: No snapshot found for version: $version" >&2
        exit 1
    fi
    
    echo "$snapshot_name"
}

# Function to extract SHA references from snapshot using existing script
extract_sha_references() {
    local snapshot_name="$1"
    
    # Use the configured snapshot content script
    local snapshot_data
    snapshot_data=$("$SNAPSHOT_CONTENT_SCRIPT" "$snapshot_name" 2>/dev/null)
    
    # Create a mapping of component names to SHA references using jq
    local sha_mapping="{}"
    
    # Process each component individually to avoid complex jq issues
    local component_count=$(echo "$snapshot_data" | jq 'length')
    
    for ((i=0; i<component_count; i++)); do
        local name=$(echo "$snapshot_data" | jq -r ".[$i].name")
        local container_image=$(echo "$snapshot_data" | jq -r ".[$i].containerImage")
        
        # Extract SHA from container image using sed
        local sha=""
        sha=${container_image##*sha256:}
        
        # Verify we got a valid SHA (64 hex characters)
        if [[ ! "$sha" =~ ^[a-f0-9]{64}$ ]]; then
            sha=""
        fi
        
        if [ -n "$sha" ]; then
            # Skip the bundle component since we're updating the bundle's own Containerfile
            if [[ "$name" == *"bundle"* ]]; then
                continue
            fi
            
            # Map component name to SHA
            sha_mapping=$(echo "$sha_mapping" | jq --arg name "$name" --arg sha "$sha" '. + {($name): $sha}')
        fi
    done
    
    echo "$sha_mapping"
}

# Function to get ARG name for a component
get_arg_name_for_component() {
    local component="$1"
    local containerfile="$2"
    
    # Handle specific known mappings first
    case "$component" in
        *"console-plugin"*)
            echo "UI_PLUGIN_IMAGE"
            return 0
            ;;
        *"populator-controller"*)
            echo "POPULATOR_CONTROLLER_IMAGE"
            return 0
            ;;
    esac
    
    # First, try to find existing ARG lines in the containerfile
    local existing_args
    existing_args=$(grep "^ARG.*_IMAGE=" "$containerfile" | sed 's/^ARG \([^=]*\)=.*/\1/' || true)
    
    # Try to match component to existing ARG names
    for arg in $existing_args; do
        # Convert ARG name to component pattern
        local arg_pattern=$(echo "$arg" | sed 's/_IMAGE$//' | tr '_' '-' | tr '[:upper:]' '[:lower:]')
        
        # Check if component matches this ARG pattern
        if [[ "$component" == *"$arg_pattern"* ]] || [[ "$arg_pattern" == *"$(echo "$component" | sed 's/-[0-9].*$//')"* ]]; then
            echo "$arg"
            return 0
        fi
    done
    
    # If no match found, try dynamic generation
    local base_name=$(echo "$component" | sed 's/-[0-9].*$//' | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    echo "${base_name}_IMAGE"
}

# Function to update Containerfile-downstream files
update_containerfile_shas() {
    local sha_mapping="$1"
    local dry_run="$2"
    local target_branch="$3"
    local changes_made=false
    
    log "Updating Containerfile-downstream files with new SHA references"
    
    # Build the containerfile URL using the configured variables
    local containerfile_url="${CONTAINERFILE_BASE_URL}/${target_branch}/${CONTAINERFILE_PATH}"
    local temp_containerfile="/tmp/Containerfile-downstream-$$"
    
    log "Downloading latest Containerfile-downstream from GitHub branch: $target_branch"
    log "URL: $containerfile_url"
    if ! curl -s -o "$temp_containerfile" "$containerfile_url"; then
        log "ERROR: Failed to download Containerfile-downstream from GitHub branch: $target_branch"
        return 1
    fi
    
    if [ ! -f "$temp_containerfile" ] || [ ! -s "$temp_containerfile" ]; then
        log "ERROR: Downloaded Containerfile-downstream is empty or missing"
        rm -f "$temp_containerfile"
        return 1
    fi
    
    log "Processing: $containerfile_url (downloaded to $temp_containerfile)"
    local containerfile="$temp_containerfile"
    
    # Create backup
    local backup_file="${containerfile}.backup"
    cp "$containerfile" "$backup_file"
    
    # Update SHA references in the file
    local updated=false
    
    # Update each component's SHA reference
    for component in $(echo "$sha_mapping" | jq -r 'keys[]' 2>/dev/null); do
        local new_sha=$(echo "$sha_mapping" | jq -r --arg comp "$component" '.[$comp]' 2>/dev/null)
        
        # Get ARG name for this component
        local arg_name
        arg_name=$(get_arg_name_for_component "$component" "$containerfile")
        
        if [ -n "$arg_name" ]; then
            # Update the ARG line with new SHA
            local old_line
            old_line=$(grep "^ARG ${arg_name}=" "$containerfile" || true)
            
            if [ -n "$old_line" ]; then
                # Extract the current SHA from the existing line
                local current_sha=""
                if [[ "$old_line" =~ @sha256:([a-f0-9]{64}) ]]; then
                    current_sha="${BASH_REMATCH[1]}"
                fi
                
                # Check if the SHA is already up to date
                if [ "$current_sha" = "$new_sha" ]; then
                    log "Skipping $arg_name - SHA already up to date ($new_sha)"
                    continue
                fi
                
                # Extract the current image name and replace only the SHA part
                local current_image=$(echo "$old_line" | sed 's/^ARG [^=]*="\([^"]*\)".*/\1/')
                local new_image=$(echo "$current_image" | sed "s/@sha256:[a-f0-9]\{64\}/@sha256:$new_sha/")
                local new_line="ARG ${arg_name}=\"${new_image}\""
                
                if [ "$dry_run" = "true" ]; then
                    log "DRY RUN: Would update $arg_name from:"
                    log "  $old_line"
                    log "  to:"
                    log "  $new_line"
                else
                    sed -i.bak "s|^ARG ${arg_name}=.*|${new_line}|" "$containerfile"
                    updated=true
                    log "Updated $arg_name in $containerfile"
                fi
            else
                log "ARG $arg_name not found in $containerfile, skipping"
            fi
        fi
    done
    
    if [ "$updated" = true ]; then
        changes_made=true
        log "Updated: $containerfile"
        rm -f "${containerfile}.bak"
    else
        # Restore original if no changes
        mv "$backup_file" "$containerfile"
    fi
    
    rm -f "$backup_file"
    
    # Clean up temporary file
    rm -f "$temp_containerfile"
    
    if [ "$dry_run" = "true" ]; then
        log "DRY RUN: Would have updated Containerfile-downstream files"
        return 0
    fi
    
    if [ "$changes_made" = false ]; then
        log "No changes needed in Containerfile-downstream files"
        return 1
    fi
    
    return 0
}

# Function to create PR
create_pr() {
    local version="$1"
    local target_branch="$2"
    local dry_run="$3"
    
    if [ "$dry_run" = "true" ]; then
        log "DRY RUN: Would create PR for version $version against branch $target_branch"
        return 0
    fi
    
    log "Creating PR for version $version against branch $target_branch"
    
    # Generate branch name
    local branch_name="update-sha-refs-$(date +%Y%m%d-%H%M%S)"
    
    # Create and checkout new branch
    git checkout -b "$branch_name"
    
    # Add changes
    git add forklift/build/*/Containerfile-downstream
    
    # Commit changes
    git commit -m "chore: update Containerfile-downstream SHA references from snapshot

- Updated SHA references for version $version
- Generated from latest snapshot
- Automated update via mtv-releng script"

    # Push branch
    git push origin "$branch_name"
    
    # Create PR
    local pr_title="Update Containerfile-downstream SHA references for $version"
    local pr_body="This PR updates the SHA references in Containerfile-downstream files based on the latest snapshot for version $version.

## Changes
- Updated SHA references in all Containerfile-downstream files
- Generated from latest snapshot: $(get_latest_snapshot "$version")

## Automated Update
This PR was created automatically by the mtv-releng update script."

    gh pr create \
        --title "$pr_title" \
        --body "$pr_body" \
        --base "$target_branch" \
        --head "$branch_name"
    
    log "PR created successfully"
}

# Function to cleanup
cleanup() {
    log "Cleaning up temporary files"
    rm -f /tmp/sha_mapping_*.json
}

# Main function
main() {
    # Parse arguments
    if [ $# -lt 1 ]; then
        usage
    fi
    
    local version="$1"
    local target_branch="${2:-main}"
    local dry_run="${3:-true}"
    
    # Validate tools
    validate_tools
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    log "Starting SHA reference update process"
    log "Version: $version"
    log "Target branch: $target_branch"
    log "Dry run: $dry_run"
    
    # Get latest snapshot
    local snapshot_name
    snapshot_name=$(get_latest_snapshot "$version")
    log "Found snapshot: $snapshot_name"
    
    # Extract SHA references
    local sha_mapping
    sha_mapping=$(extract_sha_references "$snapshot_name")
    
    log "SHA mapping extracted:"
    if echo "$sha_mapping" | jq . >/dev/null 2>&1; then
        echo "$sha_mapping" | jq .
    else
        log "Error: Invalid JSON in SHA mapping"
        log "SHA mapping content: $sha_mapping"
        return 1
    fi

    # Log the results
    local sha_count=$(echo "$sha_mapping" | jq 'keys | length' 2>/dev/null || echo "0")
    log "Found $sha_count components with SHA references (bundle component excluded)"
    
    # Update Containerfile-downstream files
    if update_containerfile_shas "$sha_mapping" "$dry_run" "$target_branch"; then
        if [ "$dry_run" = "false" ]; then
            # Create PR
            create_pr "$version" "$target_branch" "$dry_run"
        else
            log "Dry run completed - no changes made"
        fi
    else
        log "No changes needed or dry run completed"
    fi
    
    log "Process completed successfully"
}

# Run main function with all arguments
main "$@"

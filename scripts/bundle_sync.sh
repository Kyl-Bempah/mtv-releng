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

# Target repository for PR creation
: "${TARGET_REPO:=Kyl-Bempah/forklift}"

# Extraction script paths
: "${LATEST_SNAPSHOT_SCRIPT:=./scripts/latest_snapshot.sh}"
: "${SNAPSHOT_CONTENT_SCRIPT:=./scripts/snapshot_content.sh}"

# Component mapping configuration file
: "${COMPONENT_MAPPINGS_FILE:=./scripts/component_mappings.conf}"

# ============================================================================


# Function to print usage
usage() {
    echo "Usage: $0 <version> [target_branch] [dry_run]"
    echo ""
    echo "Arguments:"
    echo "  version       - Version to get snapshot for (e.g., '2-10', 'dev-preview')"
    echo "  target_branch - Target branch for PR (default: 'main')"
    echo "  dry_run       - Set to 'true' to only show what would be changed (default: 'true')"
    echo ""
    echo "Environment Variables:"
    echo "  TARGET_REPO              - Target repository for PR creation (default: 'kubev2v/forklift')"
    echo "  COMPONENT_MAPPINGS_FILE  - Component mapping configuration file (default: './scripts/component_mappings.conf')"
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
    
    # Remove version suffix to get base component name
    # Handle patterns like: -2-10, -dev-preview, -rc1, etc.
    local base_component="$component"
    # Remove numeric version suffixes (e.g., -2-10, -1.0.0)
    base_component=$(echo "$base_component" | sed 's/-[0-9].*$//')
    # Remove common non-numeric suffixes
    base_component=$(echo "$base_component" | sed 's/-dev-preview$//; s/-rc[0-9]*$//; s/-alpha$//; s/-beta$//; s/-stable$//')
    
    # Try to find mapping in configuration file
    if [ -f "$COMPONENT_MAPPINGS_FILE" ]; then
        local arg_name
        arg_name=$(grep "^${base_component}=" "$COMPONENT_MAPPINGS_FILE" 2>/dev/null | cut -d'=' -f2)
        if [ -n "$arg_name" ]; then
            # Check if the ARG exists in the containerfile
            if grep -q "^ARG ${arg_name}=" "$containerfile" 2>/dev/null; then
                echo "$arg_name"
                return 0
            fi
        fi
    fi
    
    # Fallback: try to find existing ARG that matches the component
    local existing_args
    existing_args=$(grep "^ARG.*_IMAGE=" "$containerfile" | sed 's/^ARG \([^=]*\)=.*/\1/' || true)
    
    for arg in $existing_args; do
        # Convert ARG name to component pattern
        local arg_pattern=$(echo "$arg" | sed 's/_IMAGE$//' | tr '_' '-' | tr '[:upper:]' '[:lower:]')
        
        # Check if component matches this ARG pattern
        if [[ "$base_component" == *"$arg_pattern"* ]] || [[ "$arg_pattern" == *"$base_component"* ]]; then
            echo "$arg"
            return 0
        fi
    done
    
    # If no match found, return empty
    echo ""
}

# Function to update Containerfile-downstream files
update_containerfile_shas() {
    local sha_mapping="$1"
    local dry_run="$2"
    local target_branch="$3"
    local temp_dir="$4"
    
    local changes_made=false
    local updated_files=""
    local containerfile=""
    
    if [ "$dry_run" = "true" ]; then
        log "DRY RUN: Analyzing Containerfile-downstream files for SHA reference updates"
        
        # Download file directly for dry run
        local containerfile_url="${CONTAINERFILE_BASE_URL}/${target_branch}/${CONTAINERFILE_PATH}"
        containerfile="/tmp/Containerfile-downstream-dry-run-$$"
        
        if ! curl -s -o "$containerfile" "$containerfile_url"; then
            log "ERROR: Failed to download Containerfile-downstream from GitHub branch: $target_branch"
            return 1
        fi
        if [ ! -f "$containerfile" ] || [ ! -s "$containerfile" ]; then
            log "ERROR: Downloaded Containerfile-downstream is empty or missing"
            rm -f "$containerfile"
            return 1
        fi
    else
        log "Updating Containerfile-downstream files with new SHA references"
        
        # Prepare target repository (clone and checkout)
        prepare_target_repo "$target_branch" "$temp_dir"
        
        # Work with the cloned repository
        containerfile="${temp_dir}/${CONTAINERFILE_PATH}"
        
        if [ ! -f "$containerfile" ]; then
            log "ERROR: Containerfile-downstream not found at $containerfile"
            return 1
        fi
        
        # Create backup
        local backup_file="${containerfile}.backup"
        cp "$containerfile" "$backup_file"
    fi
    
    log "Processing: $containerfile"
    
    # Update SHA references in the file
    local updated=false
    
    
    # Track components for reporting
    local components_processed=0
    local components_updated=0
    local components_skipped=0
    local components_missing=0
    
    # Update each component's SHA reference
    for component in $(echo "$sha_mapping" | jq -r 'keys[]' 2>/dev/null); do
        local new_sha=$(echo "$sha_mapping" | jq -r --arg comp "$component" '.[$comp]' 2>/dev/null)
        components_processed=$((components_processed + 1))
        
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
                    components_skipped=$((components_skipped + 1))
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
                components_updated=$((components_updated + 1))
            else
                log "WARNING: ARG $arg_name not found in $containerfile - component may have been removed or ARG name changed"
                components_missing=$((components_missing + 1))
            fi
        else
            log "WARNING: Could not determine ARG name for component: $component - may be a new component"
            components_missing=$((components_missing + 1))
        fi
    done
    
    # Check for ARG lines in Containerfile that don't have corresponding components in snapshot
    # This helps detect removed components
    local containerfile_args
    containerfile_args=$(grep "^ARG.*_IMAGE=" "$containerfile" | sed 's/^ARG \([^=]*\)=.*/\1/' || true)
    local snapshot_components
    snapshot_components=$(echo "$sha_mapping" | jq -r 'keys[]' 2>/dev/null || true)
    
    local orphaned_args=0
    for arg in $containerfile_args; do
        local found=false
        for component in $snapshot_components; do
            local expected_arg
            expected_arg=$(get_arg_name_for_component "$component" "$containerfile")
            if [ "$arg" = "$expected_arg" ]; then
                found=true
                break
            fi
        done
        if [ "$found" = "false" ]; then
            log "INFO: ARG $arg exists in Containerfile but has no corresponding component in snapshot - may be a removed component"
            orphaned_args=$((orphaned_args + 1))
        fi
    done
    
    # Report component processing summary
    log "Component processing summary:"
    log "  - Processed: $components_processed"
    log "  - Updated: $components_updated"
    log "  - Skipped (up to date): $components_skipped"
    log "  - Missing/Unknown: $components_missing"
    log "  - Orphaned ARGs (removed components): $orphaned_args"
    
    
    # Set changes_made based on whether any components were updated
    if [ "$components_updated" -gt 0 ]; then
        changes_made=true
    fi
    
    if [ "$dry_run" = "true" ]; then
        # Clean up temporary file
        rm -f "$containerfile"
        if [ "$components_updated" -eq 0 ]; then
            log "DRY RUN: No changes needed in Containerfile-downstream files"
        else
            log "DRY RUN: Would have updated Containerfile-downstream files"
        fi
        return 0
    fi
    
    if [ "$updated" = true ]; then
        changes_made=true
        updated_files="$containerfile"
        log "Updated: $containerfile"
        rm -f "${containerfile}.bak"
    else
        # Restore original if no changes
        mv "$backup_file" "$containerfile"
    fi
    
    rm -f "$backup_file"
    
    if [ "$changes_made" = false ]; then
        log "No changes needed in Containerfile-downstream files"
        return 1
    fi
    
    # Return the updated files
    echo "$updated_files"
    return 0
}

# Function to clone and prepare target repository
prepare_target_repo() {
    local target_branch="$1"
    local temp_dir="$2"
    
    log "Cloning target repository: $TARGET_REPO"
    cd "$temp_dir"
    
    # Clone the target repository
    git clone "https://github.com/$TARGET_REPO.git" .
    
    # Checkout the target branch
    git checkout "$target_branch"
    git pull origin "$target_branch"
    
    # Configure git to use GitHub CLI for authentication
    git config credential.helper 'gh auth git-credential'
    
    log "Repository prepared successfully"
}

# Function to create PR
create_pr() {
    local version="$1"
    local target_branch="$2"
    local dry_run="$3"
    local updated_files="$4"
    local temp_dir="$5"
    
    if [ "$dry_run" = "true" ]; then
        log "DRY RUN: Would create PR for version $version against branch $target_branch in repo $TARGET_REPO"
        return 0
    fi
    
    log "Creating PR for version $version against branch $target_branch in repo $TARGET_REPO"
    
    # Change to the cloned repository directory
    cd "$temp_dir"
    
    # Generate branch name
    local branch_name="update-sha-refs-$(date +%Y%m%d-%H%M%S)"
    
    # Create and checkout new branch
    git checkout -b "$branch_name"
    
    # Add the updated files
    for file in $updated_files; do
        if [ -f "$file" ]; then
            git add "$file"
        fi
    done
    
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
        --repo "$TARGET_REPO" \
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
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
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
    
    # Create temporary directory for cloned repository
    TEMP_DIR=$(mktemp -d)
    log "Created temporary directory: $TEMP_DIR"
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    log "Starting SHA reference update process"
    log "Version: $version"
    log "Target branch: $target_branch"
    log "Target repository: $TARGET_REPO"
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
    local updated_files
    local update_result
    
    # For both dry run and actual run, we need to capture the output but also display it
    # Use a temporary file to capture the return value
    local temp_result_file="/tmp/bundle_sync_result_$$"
    update_containerfile_shas "$sha_mapping" "$dry_run" "$target_branch" "$TEMP_DIR" > "$temp_result_file" 2>&1
    update_result=$?
    # Display the output
    cat "$temp_result_file"
    # Extract the updated files from the output (if any)
    updated_files=$(grep "Updated:" "$temp_result_file" | sed 's/.*Updated: //' || true)
    rm -f "$temp_result_file"
    
    if [ $update_result -eq 0 ]; then
        if [ "$dry_run" = "false" ]; then
            # Create PR
            create_pr "$version" "$target_branch" "$dry_run" "$updated_files" "$TEMP_DIR"
        else
            log "Dry run completed - no changes made"
        fi
    else
        if [ "$dry_run" = "true" ]; then
            log "Dry run completed - no changes needed"
        else
            log "No changes needed"
        fi
    fi
    
    log "Process completed successfully"
}

# Run main function with all arguments
main "$@"

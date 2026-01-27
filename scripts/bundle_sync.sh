#!/usr/bin/env bash

# Script to update Containerfile-downstream SHA references with latest snapshot
# and create a PR against the correct branch in the forklift repo

set -e

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/util.sh"

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
: "${LATEST_SNAPSHOT_SCRIPT:=$SCRIPT_DIR/latest_snapshot.sh}"
: "${SNAPSHOT_CONTENT_SCRIPT:=$SCRIPT_DIR/snapshot_content.sh}"

# Component mapping configuration file
: "${COMPONENT_MAPPINGS_FILE:=$SCRIPT_DIR/component_mappings.conf}"

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

# Function to get the latest virt-v2v-int SHA from quay (latest on-push tag)
get_latest_virt_v2v_int_sha() {
    local version="$1"
    
    if [ -z "$version" ]; then
        log_error "Version is required to fetch virt-v2v-int SHA"
        return 1
    fi
    
    # Construct the repository path
    local repo_path="redhat-user-workloads/rh-mtv-btrfs-tenant/forklift-operator-int-${version}/virt-v2v-int-${version}"
    local image_base="quay.io/${repo_path}"
    
    log "Fetching latest virt-v2v-int SHA for version: $version" >&2
    log "Repository: $image_base" >&2
    
    # Use Quay.io API to list tags
    local api_url="https://quay.io/api/v1/repository/${repo_path}/tag/"
    local tags_response
    
    if ! tags_response=$(curl -s -f "$api_url" 2>/dev/null); then
        log_error "Failed to fetch tags from Quay.io API: $api_url"
        return 1
    fi
    
    # Validate API response
    if echo "$tags_response" | jq -e '.error_message' >/dev/null 2>&1; then
        local error_msg=$(echo "$tags_response" | jq -r '.error_message')
        log_error "Quay.io API error: $error_msg"
        return 1
    fi
    
    if ! echo "$tags_response" | jq -e '.tags' >/dev/null 2>&1; then
        log_error "Invalid API response from Quay.io. Response: $tags_response"
        return 1
    fi
    
    # Extract tags and filter for "on-push" tags, then sort by creation date (newest first)
    local latest_tag
    latest_tag=$(echo "$tags_response" | jq -r '[.tags[] | select(.name | index("on-push") != null) | {name: .name, start_ts: .start_ts}] | sort_by(.start_ts) | reverse | .[0].name' 2>/dev/null)
    
    if [ -z "$latest_tag" ] || [ "$latest_tag" = "null" ]; then
        log_error "No on-push tags found for virt-v2v-int-${version}"
        return 1
    fi
    
    log "Found latest on-push tag: $latest_tag" >&2
    
    # Get the SHA for this tag using skopeo
    local image_with_tag="${image_base}:${latest_tag}"
    local manifest_digest
    
    if ! manifest_digest=$(skopeo inspect "docker://${image_with_tag}" 2>/dev/null | jq -r '.Digest' 2>/dev/null); then
        log_error "Failed to get manifest digest for ${image_with_tag}"
        return 1
    fi
    
    # Extract just the SHA part (remove "sha256:" prefix)
    local sha="${manifest_digest#sha256:}"
    
    if [[ ! "$sha" =~ ^[a-f0-9]{64}$ ]]; then
        log_error "Invalid SHA format: $sha"
        return 1
    fi
    
    log_success "Found virt-v2v-int SHA: $sha (from tag: $latest_tag)" >&2
    echo "$sha"
    return 0
}

# Function to validate that components from snapshot actually exist in quay
validate_components_in_quay() {
    local snapshot_data="$1"
    
    if [ -z "$snapshot_data" ]; then
        log_error "No snapshot data provided for validation"
        return 1
    fi
    
    # Check if skopeo is available
    if ! command -v skopeo &> /dev/null; then
        log_error "skopeo is required for component validation but is not installed"
        return 1
    fi
    
    log "Validating components exist in quay..." >&2
    
    local component_count=$(echo "$snapshot_data" | jq 'length')
    local validated_count=0
    local failed_count=0
    local failed_components=()
    
    # Process each component
    for ((i=0; i<component_count; i++)); do
        local name=$(echo "$snapshot_data" | jq -r ".[$i].name")
        local container_image=$(echo "$snapshot_data" | jq -r ".[$i].containerImage")
        
        if [ -z "$container_image" ] || [ "$container_image" = "null" ]; then
            log_warning "Component $name has no containerImage, skipping validation" >&2
            continue
        fi
        
        # Skip virt-v2v validation - it's fetched from a different location (virt-v2v-int)
        if [[ "$name" == *"virt-v2v"* ]] && [[ "$name" != *"virt-v2v-int"* ]]; then
            log "Skipping validation for $name (will be fetched from virt-v2v-int repository)" >&2
            continue
        fi
        
        # Use skopeo to check if the image exists
        # skopeo inspect will return non-zero exit code if image doesn't exist
        if skopeo inspect "docker://${container_image}" &>/dev/null; then
            validated_count=$((validated_count + 1))
            log "✓ Validated: $name" >&2
        else
            failed_count=$((failed_count + 1))
            failed_components+=("$name")
            log_error "✗ Failed to validate: $name (image: $container_image)"
        fi
    done
    
    # Report summary
    log "Validation summary:" >&2
    log "  - Validated: $validated_count" >&2
    log "  - Failed: $failed_count" >&2
    
    # If any components failed, report them and return error
    if [ $failed_count -gt 0 ]; then
        log_error "The following components do not exist in quay:"
        for component in "${failed_components[@]}"; do
            log_error "  - $component"
        done
        return 1
    fi
    
    log_success "All components validated successfully in quay" >&2
    return 0
}

# Function to extract SHA references from snapshot using existing script
extract_sha_references() {
    local snapshot_name="$1"
    local version="$2"
    
    # Use the configured snapshot content script
    local snapshot_data
    snapshot_data=$("$SNAPSHOT_CONTENT_SCRIPT" "$snapshot_name" 2>/dev/null)
    
    # Validate components exist in quay before processing
    if ! validate_components_in_quay "$snapshot_data"; then
        log_error "Component validation failed. Aborting SHA reference extraction."
        return 1
    fi
    
    # Create a mapping of component names to SHA references using jq
    local sha_mapping="{}"
    
    # Process each component individually to avoid complex jq issues
    local component_count=$(echo "$snapshot_data" | jq 'length')
    
    for ((i=0; i<component_count; i++)); do
        local name=$(echo "$snapshot_data" | jq -r ".[$i].name")
        local container_image=$(echo "$snapshot_data" | jq -r ".[$i].containerImage")
        
        # Skip virt-v2v components - we'll get it from quay separately
        if [[ "$name" == *"virt-v2v"* ]] && [[ "$name" != *"virt-v2v-int"* ]]; then
            log "Skipping $name from snapshot (will fetch virt-v2v-int from quay instead)" >&2
            continue
        fi
        
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
    
    # Get virt-v2v-int SHA from quay (latest on-push tag)
    if [ -n "$version" ]; then
        local virt_v2v_sha
        local virt_v2v_stdout="/tmp/virt_v2v_stdout_$$"
        local virt_v2v_stderr="/tmp/virt_v2v_stderr_$$"
        # Capture stdout (SHA) and stderr (logs) separately
        # Redirect all log output to stderr by wrapping the function call
        if get_latest_virt_v2v_int_sha "$version" > "$virt_v2v_stdout" 2> "$virt_v2v_stderr"; then
            # Display logs to stderr
            cat "$virt_v2v_stderr" >&2
            # Get the SHA from stdout (should be just the SHA, no logs)
            virt_v2v_sha=$(cat "$virt_v2v_stdout" 2>/dev/null | grep -v "^$" | tail -1)
            rm -f "$virt_v2v_stdout" "$virt_v2v_stderr"
            
            if [ -z "$virt_v2v_sha" ]; then
                log_warning "Failed to extract SHA from virt-v2v-int output" >&2
            else
                # Add virt-v2v to the mapping (using the name pattern that matches the component mapping)
                # The component name in snapshot might be "virt-v2v-<version>" but we need to map it correctly
                local virt_v2v_name="virt-v2v-${version}"
                sha_mapping=$(echo "$sha_mapping" | jq --arg name "$virt_v2v_name" --arg sha "$virt_v2v_sha" '. + {($name): $sha}')
                log "Added virt-v2v-int SHA to mapping as: $virt_v2v_name" >&2
            fi
        else
            # Display error logs
            cat "$virt_v2v_stderr" >&2
            rm -f "$virt_v2v_stdout" "$virt_v2v_stderr"
            log_warning "Failed to get virt-v2v-int SHA from quay" >&2
            # Don't fail the entire process if virt-v2v-int fetch fails, but log a warning
        fi
    else
        log_warning "Version not provided, skipping virt-v2v-int SHA fetch" >&2
    fi
    
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
        log "DRY RUN: Analyzing Containerfile-downstream files for SHA reference updates" >&2
        
        # Download file directly for dry run
        local containerfile_url="${CONTAINERFILE_BASE_URL}/${target_branch}/${CONTAINERFILE_PATH}"
        containerfile="/tmp/Containerfile-downstream-dry-run-$$"
        
        if ! curl -s -o "$containerfile" "$containerfile_url"; then
            log "ERROR: Failed to download Containerfile-downstream from GitHub branch: $target_branch" >&2
            return 1
        fi
        if [ ! -f "$containerfile" ] || [ ! -s "$containerfile" ]; then
            log "ERROR: Downloaded Containerfile-downstream is empty or missing" >&2
            rm -f "$containerfile"
            return 1
        fi
    else
        log "Updating Containerfile-downstream files with new SHA references" >&2
        
        # Prepare target repository (clone and checkout)
        prepare_target_repo "$target_branch" "$temp_dir"
        
        # Work with the cloned repository
        containerfile="${temp_dir}/${CONTAINERFILE_PATH}"
        
        if [ ! -f "$containerfile" ]; then
            log "ERROR: Containerfile-downstream not found at $containerfile" >&2
            return 1
        fi
        
        # Create backup
        local backup_file="${containerfile}.backup"
        cp "$containerfile" "$backup_file"
    fi
    
    log "Processing: $containerfile" >&2
    
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
                    log "Skipping $arg_name - SHA already up to date ($new_sha)" >&2
                    components_skipped=$((components_skipped + 1))
                    continue
                fi
                
                # Extract the current image name and replace only the SHA part
                local current_image=$(echo "$old_line" | sed 's/^ARG [^=]*="\([^"]*\)".*/\1/')
                local new_image=$(echo "$current_image" | sed "s/@sha256:[a-f0-9]\{64\}/@sha256:$new_sha/")
                local new_line="ARG ${arg_name}=\"${new_image}\""
                
                if [ "$dry_run" = "true" ]; then
                    log "DRY RUN: Would update $arg_name from:" >&2
                    log "  $old_line" >&2
                    log "  to:" >&2
                    log "  $new_line" >&2
                else
                    sed -i.bak "s|^ARG ${arg_name}=.*|${new_line}|" "$containerfile"
                    updated=true
                    log "Updated $arg_name in $containerfile" >&2
                fi
                components_updated=$((components_updated + 1))
            else
                log "WARNING: ARG $arg_name not found in $containerfile - component may have been removed or ARG name changed" >&2
                components_missing=$((components_missing + 1))
            fi
        else
            log "WARNING: Could not determine ARG name for component: $component - may be a new component" >&2
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
            log "INFO: ARG $arg exists in Containerfile but has no corresponding component in snapshot - may be a removed component" >&2
            orphaned_args=$((orphaned_args + 1))
        fi
    done
    
    # Report component processing summary
    log "Component processing summary:" >&2
    log "  - Processed: $components_processed" >&2
    log "  - Updated: $components_updated" >&2
    log "  - Skipped (up to date): $components_skipped" >&2
    log "  - Missing/Unknown: $components_missing" >&2
    log "  - Orphaned ARGs (removed components): $orphaned_args" >&2
    
    
    # Set changes_made based on whether any components were updated
    if [ "$components_updated" -gt 0 ]; then
        changes_made=true
    fi
    
    if [ "$dry_run" = "true" ]; then
        # Clean up temporary file
        rm -f "$containerfile"
        if [ "$components_updated" -eq 0 ]; then
            log "DRY RUN: No changes needed in Containerfile-downstream files" >&2
        else
            log "DRY RUN: Would have updated Containerfile-downstream files" >&2
        fi
        return 0
    fi
    
    if [ "$updated" = true ]; then
        changes_made=true
        # Return relative path (since create_pr will cd to temp_dir)
        # Note: This code only executes when dry_run=false (we return early in dry run mode)
        updated_files="$CONTAINERFILE_PATH"
        log "Updated: $containerfile" >&2
        rm -f "${containerfile}.bak"
    else
        # Restore original if no changes
        mv "$backup_file" "$containerfile"
    fi
    
    rm -f "$backup_file"
    
    if [ "$changes_made" = false ]; then
        log "No changes needed in Containerfile-downstream files" >&2
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
    
    # Configure git to use GitHub CLI for authentication (suppress errors if helper doesn't exist)
    git config credential.helper 'gh auth git-credential' 2>/dev/null || true
    
    log "Repository prepared successfully"
}

# Function to create PR
create_pr() {
    local version="$1"
    local target_branch="$2"
    local dry_run="$3"
    local updated_files="$4"
    local temp_dir="$5"
    local snapshot_name="$6"
    
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
    if [ -z "$updated_files" ]; then
        log_error "No updated files provided to create_pr"
        return 1
    fi
    
    local files_added=0
    for file in $updated_files; do
        if [ -f "$file" ]; then
            git add "$file"
            files_added=$((files_added + 1))
            log "Added file to git: $file"
        else
            log_warning "File not found: $file (skipping)"
        fi
    done
    
    if [ $files_added -eq 0 ]; then
        log_error "No files were added to git. Cannot create PR."
        return 1
    fi
    
    # Commit changes
    if ! git commit -m "chore: update Containerfile-downstream SHA references from snapshot

- Updated SHA references for version $version
- Generated from latest snapshot
- Automated update via mtv-releng script"; then
        log_error "Failed to commit changes"
        return 1
    fi
    
    log "Committed changes successfully"
    
    # Push branch
    if ! git push origin "$branch_name"; then
        log_error "Failed to push branch $branch_name"
        return 1
    fi
    
    log "Pushed branch $branch_name successfully"
    
    # Create PR
    local pr_title="chore: Update Containerfile-downstream SHA references for $version"
    local pr_body="This PR updates the SHA references in Containerfile-downstream files based on the latest snapshot for version $version.

## Changes
- Updated SHA references in all Containerfile-downstream files
- Generated from latest snapshot: ${snapshot_name}

## Automated Update
This PR was created automatically by the mtv-releng update script."

    if ! gh pr create \
        --repo "$TARGET_REPO" \
        --title "$pr_title" \
        --body "$pr_body" \
        --base "$target_branch" \
        --head "$branch_name"; then
        log_error "Failed to create PR"
        return 1
    fi
    
    log_success "PR created successfully"
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
    
    # Extract SHA references (with validation)
    # Capture stdout (JSON) and stderr (logs) separately
    local temp_sha_stdout="/tmp/bundle_sync_sha_stdout_$$"
    local temp_sha_stderr="/tmp/bundle_sync_sha_stderr_$$"
    local sha_mapping
    local extract_result
    
    if ! extract_sha_references "$snapshot_name" "$version" > "$temp_sha_stdout" 2> "$temp_sha_stderr"; then
        extract_result=$?
        # Display log output
        cat "$temp_sha_stderr" >&2
        log_error "Failed to extract SHA references. Component validation may have failed."
        rm -f "$temp_sha_stdout" "$temp_sha_stderr"
        return 1
    fi
    extract_result=$?
    
    # Display log output
    cat "$temp_sha_stderr" >&2
    
    # Get the JSON from stdout - read entire content, jq can handle multi-line JSON
    sha_mapping=$(cat "$temp_sha_stdout" 2>/dev/null)
    rm -f "$temp_sha_stdout" "$temp_sha_stderr"
    
    if [ $extract_result -ne 0 ]; then
        log_error "Failed to extract SHA references"
        return 1
    fi
    
    if [ -z "$sha_mapping" ]; then
        log_error "SHA mapping is empty"
        return 1
    fi
    
    log "SHA mapping extracted:"
    if ! echo "$sha_mapping" | jq . >/dev/null 2>&1; then
        log_error "Invalid JSON in SHA mapping"
        log_error "SHA mapping content (first 500 chars): ${sha_mapping:0:500}"
        return 1
    fi
    
    # Display the JSON
    echo "$sha_mapping" | jq .

    # Log the results
    local sha_count=$(echo "$sha_mapping" | jq 'keys | length' 2>/dev/null || echo "0")
    log "Found $sha_count components with SHA references (bundle component excluded)"
    log "Proceeding to update Containerfile-downstream files..."
    
    # Update Containerfile-downstream files
    local updated_files
    local update_result
    
    # For both dry run and actual run, we need to capture the output but also display it
    # Use a temporary file to capture the return value and stdout separately
    local temp_result_file="/tmp/bundle_sync_result_$$"
    local temp_stdout_file="/tmp/bundle_sync_stdout_$$"
    
    # Capture stdout (file paths) and stderr (logs) separately
    update_containerfile_shas "$sha_mapping" "$dry_run" "$target_branch" "$TEMP_DIR" > "$temp_stdout_file" 2> "$temp_result_file"
    update_result=$?
    
    # Display the log output
    cat "$temp_result_file"
    
    # The function outputs the file path to stdout, but we know it should be CONTAINERFILE_PATH
    # If the update was successful, use the known path (simpler and more reliable)
    if [ $update_result -eq 0 ]; then
        # Check if there's a valid path in stdout, otherwise use the default
        local extracted_path=$(cat "$temp_stdout_file" 2>/dev/null | grep -E "^[a-zA-Z0-9_/.-]+$" | grep -F "$CONTAINERFILE_PATH" | head -1 || true)
        if [ -n "$extracted_path" ] && [[ "$extracted_path" == "$CONTAINERFILE_PATH" ]]; then
            updated_files="$extracted_path"
        else
            # Use the known path - function should output it, but if stdout is corrupted, we know what it is
            updated_files="$CONTAINERFILE_PATH"
        fi
    fi
    
    rm -f "$temp_result_file" "$temp_stdout_file"
    
    log "Update result: $update_result"
    log "Updated files: '$updated_files'"
    log "Dry run: $dry_run"
    
    if [ $update_result -eq 0 ]; then
        log "Update function returned success (0)"
        if [ "$dry_run" = "false" ]; then
            log "Dry run is false, proceeding with PR creation"
            if [ -z "$updated_files" ]; then
                log_error "No updated files found, cannot create PR"
                return 1
            fi
            log "Creating PR with updated files: $updated_files"
            # Create PR (pass snapshot_name to avoid calling get_latest_snapshot again)
            if ! create_pr "$version" "$target_branch" "$dry_run" "$updated_files" "$TEMP_DIR" "$snapshot_name"; then
                log_error "Failed to create PR"
                return 1
            fi
        else
            log "Dry run is true, skipping PR creation"
            log "Dry run completed - no changes made"
        fi
    else
        log "Update function returned failure ($update_result)"
        if [ "$dry_run" = "true" ]; then
            log "Dry run completed - no changes needed"
        else
            log "No changes needed - update function returned non-zero exit code"
        fi
    fi
    
    log "Process completed successfully"
}

# Run main function with all arguments
main "$@"

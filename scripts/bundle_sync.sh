#!/usr/bin/env bash

# Script to update Containerfile-downstream SHA references with latest snapshot
# and create a PR against the correct branch in the forklift repo

set -e

# Directory containing this script (so paths work when run from any CWD)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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
: "${TARGET_REPO:=kubev2v/forklift}"

# Extraction script paths
: "${LATEST_RELEASE_SCRIPT:=./scripts/latest_release.sh}"
: "${SNAPSHOT_FROM_RELEASE_SCRIPT:=./scripts/snapshot_from_release.sh}"
: "${SNAPSHOT_CONTENT_SCRIPT:=./scripts/snapshot_content.sh}"

# Component mapping configuration file (default: same directory as this script)
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
    echo "If an open PR already exists for the same version and target branch (same title),"
    echo "the script will rebase that PR's head branch onto the latest base, apply SHA updates,"
    echo "then push (with --force-with-lease) instead of creating a new PR."
    echo ""
    echo "Environment Variables:"
    echo "  TARGET_REPO              - Target repository for PR creation (default: 'kubev2v/forklift')"
    echo "  COMPONENT_MAPPINGS_FILE  - Component mapping configuration file (default: './scripts/component_mappings.conf')"
    echo ""
    echo "Examples:"
    echo "  $0 2-10"
    echo "  $0 dev-preview release-2.10"
    echo "  $0 2-10 main true"
    echo ""
    echo "Logging: to capture a full transcript in one file, merge stderr (errors, skopeo, etc.):"
    echo "  $0 dev-preview main true >>bundle.log 2>&1"
    exit 1
}


# Function to get latest snapshot using existing script
get_latest_snapshot() {
    local version="$1"
    
    # Use the configured snapshot script
    local latest_release
    latest_release=$("$LATEST_RELEASE_SCRIPT" "$version" "stage" 2>/dev/null)
    local snapshot_name
    snapshot_name=$("$SNAPSHOT_FROM_RELEASE_SCRIPT" "$latest_release" 2>/dev/null)
    
    if [ -z "$snapshot_name" ]; then
        echo "ERROR: No snapshot found for version: $version" >&2
        exit 1
    fi
    
    echo "$snapshot_name"
}

# VIRT_V2V_IMAGE line must not match VIRT_V2V_IMAGE_RHEL9 (pattern stops before _RHEL9).
has_arg_virt_v2v_main() { grep -qE '^ARG VIRT_V2V_IMAGE[[:space:]="]' "$1" 2>/dev/null; }
has_arg_virt_v2v_rhel9() { grep -qE '^ARG VIRT_V2V_IMAGE_RHEL9[[:space:]="]' "$1" 2>/dev/null; }

# One probe: arg count, flags, and single-slot int mapping key (empty if not exactly one ARG).
# Prints: <count> <has_main> <has_rhel9> <single_slot_key_or_empty>
probe_containerfile_virt_v2v() {
    local f="$1" ver="$2"
    local has_main=0 has_rhel9=0
    has_arg_virt_v2v_main "$f" && has_main=1
    has_arg_virt_v2v_rhel9 "$f" && has_rhel9=1
    local n=$((has_main + has_rhel9)) sk=""
    if [ "$n" -eq 1 ]; then
        if [ "$has_main" -eq 1 ]; then sk="virt-v2v-${ver}"; else sk="virt-v2v-rhel9-${ver}"; fi
    fi
    echo "$n $has_main $has_rhel9 $sk"
}

# Shared rule for validate + extract: skip snapshot row when digest comes from virt-v2v-int instead.
# Exit 0 = skip this row; exit 1 = handle normally (validate skopeo / use snapshot SHA).
virt_v2v_should_skip_snapshot_row() {
    local name="$1" arg_count="$2"
    [[ "$name" == *"virt-v2v"* ]] && [[ "$name" != *"virt-v2v-int"* ]] || return 1
    [ "${arg_count:-1}" -lt 2 ] && return 0
    [[ "$name" != *"virt-v2v-rhel9"* ]] && return 0
    return 1
}

# Echoes updated JSON on stdout (always). Optional 4th arg: log line before fetch.
append_virt_v2v_int_sha_to_mapping() {
    local version="$1" current_json="$2" map_key="$3"
    local pre_log="${4:-}"
    [ -n "$pre_log" ] && log "$pre_log" >&2
    local virt_v2v_stdout="/tmp/virt_v2v_stdout_$$"
    local virt_v2v_stderr="/tmp/virt_v2v_stderr_$$"
    if get_latest_virt_v2v_int_sha "$version" > "$virt_v2v_stdout" 2> "$virt_v2v_stderr"; then
        cat "$virt_v2v_stderr" >&2
        local virt_v2v_sha
        virt_v2v_sha=$(grep -v '^$' "$virt_v2v_stdout" 2>/dev/null | tail -1)
        rm -f "$virt_v2v_stdout" "$virt_v2v_stderr"
        if [ -z "$virt_v2v_sha" ]; then
            log_warning "Failed to extract SHA from virt-v2v-int output" >&2
            echo "$current_json"
            return 0
        fi
        echo "$current_json" | jq --arg name "$map_key" --arg sha "$virt_v2v_sha" '. + {($name): $sha}'
        log "Added virt-v2v-int SHA to mapping as: $map_key" >&2
        return 0
    fi
    cat "$virt_v2v_stderr" >&2
    rm -f "$virt_v2v_stdout" "$virt_v2v_stderr"
    log_warning "Failed to get virt-v2v-int SHA from quay" >&2
    echo "$current_json"
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
# Second arg: number of virt-v2v-related ARG lines in Containerfile-downstream (0, 1, or 2).
# Single-slot: skip snapshot virt-v2v rows (digest from virt-v2v-int). Dual-slot: validate only *virt-v2v-rhel9*
# snapshot rows; skip plain *virt-v2v* rows (VIRT_V2V_IMAGE comes from virt-v2v-int quay, not snapshot).
validate_components_in_quay() {
    local snapshot_data="$1"
    local virt_v2v_arg_count="${2:-1}"
    
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
        
        if [[ "$name" == *"virt-v2v"* ]] && [[ "$name" != *"virt-v2v-int"* ]]; then
            if virt_v2v_should_skip_snapshot_row "$name" "$virt_v2v_arg_count"; then
                if [ "${virt_v2v_arg_count:-1}" -lt 2 ]; then
                    log "Skipping validation for $name (single virt-v2v ARG in bundle; SHA will come from virt-v2v-int if used)" >&2
                else
                    log "Skipping validation for $name (VIRT_V2V_IMAGE digest comes from virt-v2v-int quay, not snapshot)" >&2
                fi
                continue
            fi
            log "Validating $name from snapshot (VIRT_V2V_IMAGE_RHEL9)" >&2
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
# Third arg: target git branch (for probing Containerfile-downstream virt-v2v ARG count).
extract_sha_references() {
    local snapshot_name="$1"
    local version="$2"
    local target_branch="${3:-main}"
    
    local virt_v2v_arg_count=1
    local virt_v2v_int_key="virt-v2v-${version}"
    local has_main=0 has_rhel9=0
    local cf_probe
    cf_probe=$(mktemp)
    local containerfile_probe_url="${CONTAINERFILE_BASE_URL}/${target_branch}/${CONTAINERFILE_PATH}"
    if curl -s -f -o "$cf_probe" "$containerfile_probe_url"; then
        read -r virt_v2v_arg_count has_main has_rhel9 virt_v2v_int_key <<< "$(probe_containerfile_virt_v2v "$cf_probe" "$version")"
        if [ "$virt_v2v_arg_count" -eq 1 ] && [ -z "$virt_v2v_int_key" ]; then
            virt_v2v_int_key="virt-v2v-${version}"
        fi
        log "Containerfile-downstream on $target_branch: $virt_v2v_arg_count virt-v2v ARG(s) (VIRT_V2V_IMAGE=$has_main, VIRT_V2V_IMAGE_RHEL9=$has_rhel9)" >&2
    else
        log_warning "Could not fetch $containerfile_probe_url to detect virt-v2v ARGs; assuming single ARG and virt-v2v-int fallback" >&2
    fi
    rm -f "$cf_probe"
    
    # Use the configured snapshot content script
    local snapshot_data
    snapshot_data=$("$SNAPSHOT_CONTENT_SCRIPT" "$snapshot_name" 2>/dev/null)
    
    # Validate components exist in quay before processing (needs virt_v2v_arg_count from probe)
    if ! validate_components_in_quay "$snapshot_data" "$virt_v2v_arg_count"; then
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
        
        if [[ "$name" == *"virt-v2v"* ]] && [[ "$name" != *"virt-v2v-int"* ]]; then
            if virt_v2v_should_skip_snapshot_row "$name" "$virt_v2v_arg_count"; then
                if [ "$virt_v2v_arg_count" -lt 2 ]; then
                    log "Skipping $name from snapshot (single virt-v2v ARG; using virt-v2v-int from quay for that slot)" >&2
                else
                    log "Skipping $name from snapshot (VIRT_V2V_IMAGE uses virt-v2v-int from quay; not in snapshot)" >&2
                fi
                continue
            fi
            log "Using snapshot SHA for $name (VIRT_V2V_IMAGE_RHEL9)" >&2
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
            
            # Use base component name as key so we only have one SHA per ARG.
            # Otherwise multiple snapshot entries (e.g. forklift-controller-2-10 and
            # forklift-controller) could both map to CONTROLLER_IMAGE and we'd process
            # the same ARG twice, showing "up to date" then overwriting with the other SHA.
            local base_name
            base_name=$(get_base_component_name "$name")
            sha_mapping=$(echo "$sha_mapping" | jq --arg name "$base_name" --arg sha "$sha" '. + {($name): $sha}')
        fi
    done
    
    # virt-v2v-int: single-slot fills the only ARG; dual-slot fills VIRT_V2V_IMAGE (RHEL9 from snapshot above).
    if [ -z "$version" ]; then
        log_warning "Version not provided, skipping virt-v2v-int SHA fetch" >&2
    elif [ "$virt_v2v_arg_count" -eq 0 ]; then
        log "No VIRT_V2V_IMAGE / VIRT_V2V_IMAGE_RHEL9 ARGs in probed Containerfile; skipping virt-v2v-int fetch" >&2
    elif [ "$virt_v2v_arg_count" -eq 1 ]; then
        sha_mapping=$(append_virt_v2v_int_sha_to_mapping "$version" "$sha_mapping" "$virt_v2v_int_key" "")
    elif [ "$has_main" -eq 1 ]; then
        sha_mapping=$(append_virt_v2v_int_sha_to_mapping "$version" "$sha_mapping" "virt-v2v-${version}" \
            "Fetching virt-v2v-int for VIRT_V2V_IMAGE (internal build is not in the snapshot; RHEL9 digest comes from snapshot above)")
    else
        log "Skipping virt-v2v-int fetch (no VIRT_V2V_IMAGE ARG in probed Containerfile)" >&2
    fi
    
    echo "$sha_mapping"
}

# Function to get base component name (strip version suffix)
# Must match the logic used in get_arg_name_for_component so ARG lookup works.
get_base_component_name() {
    local component="$1"
    local base_component="$component"
    # Remove numeric version suffixes (e.g., -2-10, -1.0.0)
    base_component=$(echo "$base_component" | sed 's/-[0-9].*$//')
    # Remove common non-numeric suffixes
    base_component=$(echo "$base_component" | sed 's/-dev-preview$//; s/-rc[0-9]*$//; s/-alpha$//; s/-beta$//; s/-stable$//')
    echo "$base_component"
}

# Function to get ARG name for a component
get_arg_name_for_component() {
    local component="$1"
    local containerfile="$2"
    
    # Remove version suffix to get base component name
    local base_component
    base_component=$(get_base_component_name "$component")
    
    # Try to find mapping in configuration file
    if [ -f "$COMPONENT_MAPPINGS_FILE" ]; then
        local arg_name
        arg_name=$(grep "^${base_component}=" "$COMPONENT_MAPPINGS_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$arg_name" ]; then
            # Check if the ARG exists in the containerfile (allow optional space before =)
            if grep -qE "^ARG ${arg_name}[[:space:]]*=" "$containerfile" 2>/dev/null; then
                echo "$arg_name"
                return 0
            fi
        fi
    fi
    
    # Fallback: try to find existing ARG that matches the component.
    # Prefer the longest (most specific) match so e.g. "populator-controller" maps to
    # POPULATOR_CONTROLLER_IMAGE, not CONTROLLER_IMAGE (both contain "controller").
    local existing_args
    existing_args=$(grep -E "^ARG[[:space:]]+[A-Za-z0-9_]+_IMAGE[[:space:]]*=" "$containerfile" 2>/dev/null | sed -E 's/^ARG[[:space:]]+([^=]+)=.*/\1/' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
    
    local best_arg=""
    local best_pattern_len=0
    for arg in $existing_args; do
        [ -z "$arg" ] && continue
        # Convert ARG name to component pattern (e.g. UI_PLUGIN_IMAGE -> ui-plugin)
        local arg_pattern=$(echo "$arg" | sed 's/_IMAGE$//' | tr '_' '-' | tr '[:upper:]' '[:lower:]')
        
        # Check if component matches this ARG pattern
        if [[ "$base_component" == *"$arg_pattern"* ]] || [[ "$arg_pattern" == *"$base_component"* ]]; then
            # Keep the longest matching pattern so populator-controller -> POPULATOR_CONTROLLER_IMAGE not CONTROLLER_IMAGE
            if [ ${#arg_pattern} -gt "$best_pattern_len" ]; then
                best_arg="$arg"
                best_pattern_len=${#arg_pattern}
            fi
        fi
    done
    if [ -n "$best_arg" ]; then
        echo "$best_arg"
        return 0
    fi
    
    # If no match found, return empty
    echo ""
}

# Function to update Containerfile-downstream files
# If existing_branch (5th arg) is set and not dry_run, prepare_target_repo will checkout that branch
# and rebase it onto the base branch. In dry_run, existing_branch selects which raw branch to fetch
# for preview (PR head when updating an existing PR).
update_containerfile_shas() {
    local sha_mapping="$1"
    local dry_run="$2"
    local target_branch="$3"
    local temp_dir="$4"
    local existing_branch="${5:-}"
    
    local changes_made=false
    local updated_files=""
    local containerfile=""
    
    if [ "$dry_run" = "true" ]; then
        local file_branch="$target_branch"
        if [ -n "$existing_branch" ]; then
            file_branch="$existing_branch"
            log "DRY RUN: Open sync PR exists (head $existing_branch → base $target_branch)" >&2
            log "DRY RUN: A live run would rebase $existing_branch onto origin/$target_branch, apply SHA edits below, commit, and git push --force-with-lease" >&2
            log "DRY RUN: Preview fetches raw Containerfile from branch $file_branch (tip of PR head; may differ slightly from post-rebase file if the base branch changed this path)" >&2
        else
            log "DRY RUN: No matching open PR; a live run would branch from $target_branch, apply edits, push, and open a new PR" >&2
            log "DRY RUN: Preview fetches raw Containerfile from branch $file_branch" >&2
        fi
        log "DRY RUN: Analyzing Containerfile-downstream for SHA reference updates (no repo clone, no writes)" >&2
        
        # Download file directly for dry run (PR head when updating an existing PR, else base branch)
        local containerfile_url="${CONTAINERFILE_BASE_URL}/${file_branch}/${CONTAINERFILE_PATH}"
        containerfile="/tmp/Containerfile-downstream-dry-run-$$"
        
        if ! curl -s -f -o "$containerfile" "$containerfile_url"; then
            log "ERROR: Failed to download Containerfile-downstream from: $containerfile_url" >&2
            return 1
        fi
        if [ ! -f "$containerfile" ] || [ ! -s "$containerfile" ]; then
            log "ERROR: Downloaded Containerfile-downstream is empty or missing" >&2
            rm -f "$containerfile"
            return 1
        fi
    else
        log "Updating Containerfile-downstream files with new SHA references" >&2
        
        # Prepare target repository (clone and checkout; use existing_branch if updating a PR)
        prepare_target_repo "$target_branch" "$temp_dir" "$existing_branch"
        
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
    # This helps detect removed components (use same pattern as get_arg_name_for_component fallback)
    local containerfile_args
    containerfile_args=$(grep -E "^ARG[[:space:]]+[A-Za-z0-9_]+_IMAGE[[:space:]]*=" "$containerfile" 2>/dev/null | sed -E 's/^ARG[[:space:]]+([^=]+)=.*/\1/' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
    local snapshot_components
    snapshot_components=$(echo "$sha_mapping" | jq -r 'keys[]' 2>/dev/null || true)
    
    local orphaned_args=0
    for arg in $containerfile_args; do
        [ -z "$arg" ] && continue
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
    local _p="" _u="Updated" _s="Skipped (up to date)" _m="Missing/Unknown" _o="Orphaned ARGs (removed components)"
    if [ "$dry_run" = "true" ]; then
        _p="DRY RUN: "
        _u="Would update"
        _s="Unchanged (SHA already latest)"
        _m="Missing/unknown mapping"
        _o="Orphaned ARGs (no snapshot component)"
        log "${_p}Component processing summary (preview only):" >&2
    else
        log "Component processing summary:" >&2
    fi
    log "  - Processed: $components_processed" >&2
    log "  - ${_u}: $components_updated" >&2
    log "  - ${_s}: $components_skipped" >&2
    log "  - ${_m}: $components_missing" >&2
    log "  - ${_o}: $orphaned_args" >&2
    
    
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
        # Machine-readable for main() — stdout only; keeps dry-run PR preview accurate
        echo "BUNDLE_SYNC_DRY_RUN_WOULD_UPDATE=$components_updated"
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

# Function to find an existing open sync PR for this version and target branch
# gh pr list returns newest first; we use the first (newest) match. Outputs head branch name to stdout if found. Returns 0 if found, 1 if none.
find_existing_sync_pr() {
    local version="$1"
    local target_branch="$2"
    local pr_list_json
    # Use same title format as create_pr() so we actually find existing PRs
    local title_pattern="chore(automation): Bundle SHA reference update for ${version}"

    if ! pr_list_json=$(gh pr list --repo "$TARGET_REPO" --base "$target_branch" --state open --json number,headRefName,title --limit 50 2>/dev/null); then
        return 1
    fi

    local match_branch match_count
    match_branch=$(echo "$pr_list_json" | jq -r --arg t "$title_pattern" 'map(select(.title == $t)) | .[0].headRefName // empty' 2>/dev/null)
    match_count=$(echo "$pr_list_json" | jq --arg t "$title_pattern" '[.[] | select(.title == $t)] | length' 2>/dev/null || echo "0")

    if [ -z "$match_branch" ] || [ "$match_branch" = "null" ]; then
        return 1
    fi
    if [ "$match_count" -gt 1 ]; then
        log "Multiple open PRs with matching title; using the newest (branch: $match_branch)" >&2
    fi
    echo "$match_branch"
    return 0
}

# Function to clone and prepare target repository
# If existing_branch is set (third arg), checkout that branch and rebase onto origin/target_branch.
# If rebase hits conflicts: git rebase --abort, then git merge origin/<base> (sets BUNDLE_SYNC_EXISTING_BRANCH_PUSH_MODE=merge for a non-force push).
prepare_target_repo() {
    local target_branch="$1"
    local temp_dir="$2"
    local existing_branch="${3:-}"
    
    log "Cloning target repository: $TARGET_REPO"
    cd "$temp_dir"
    
    # Clone the target repository
    git clone "https://github.com/$TARGET_REPO.git" .
    
    # Checkout the target branch
    git checkout "$target_branch"
    git pull origin "$target_branch"
    
    # Configure git to use GitHub CLI for authentication (suppress errors if helper doesn't exist)
    git config credential.helper 'gh auth git-credential' 2>/dev/null || true
    
    if [ -n "$existing_branch" ]; then
        log "Checking out existing sync branch: $existing_branch"
        git fetch origin "$existing_branch"
        git checkout "$existing_branch"
        log "Rebasing $existing_branch onto origin/$target_branch (latest base)"
        if ! git rebase "origin/$target_branch"; then
            log_warning "Rebase stopped (conflicts or merge-binary issues). Aborting rebase and merging origin/$target_branch instead."
            if ! git rebase --abort; then
                log_error "Could not git rebase --abort; fix the clone under $temp_dir manually and re-run."
                return 1
            fi
            if ! git merge "origin/$target_branch" -m "Merge $target_branch into $existing_branch (bundle_sync: rebase had conflicts)"; then
                log_error "Merge of origin/$target_branch also failed (conflicts). Resolve on branch $existing_branch locally, push, then re-run this script."
                git merge --abort 2>/dev/null || true
                return 1
            fi
            export BUNDLE_SYNC_EXISTING_BRANCH_PUSH_MODE=merge
            log_success "Merged origin/$target_branch into $existing_branch; ready to apply SHA updates (use regular push, not force)"
        else
            export BUNDLE_SYNC_EXISTING_BRANCH_PUSH_MODE=rebase
            log_success "Rebased $existing_branch onto latest $target_branch; ready to apply SHA updates"
        fi
    else
        log "Repository prepared on $target_branch (no existing sync PR branch to rebase)"
    fi
}

# Function to create PR or update an existing sync PR
# If existing_branch (7th arg) is set, push to that branch instead of creating a new PR
create_pr() {
    local version="$1"
    local target_branch="$2"
    local dry_run="$3"
    local updated_files="$4"
    local temp_dir="$5"
    local snapshot_name="$6"
    local existing_branch="${7:-}"
    
    if [ "$dry_run" = "true" ]; then
        if [ -n "$existing_branch" ]; then
            log "DRY RUN: Would git add/commit on $existing_branch, push (--force-with-lease after rebase, or plain push after merge fallback), and refresh existing PR (base $target_branch) for version $version in $TARGET_REPO"
        else
            log "DRY RUN: Would git add/commit, git push, and gh pr create --base $target_branch for version $version in $TARGET_REPO"
        fi
        return 0
    fi
    
    if [ -n "$existing_branch" ]; then
        log "Committing and pushing rebased branch $existing_branch to update open PR (base $target_branch, version $version, repo $TARGET_REPO)"
    else
        log "Creating new branch, commit, push, and PR for version $version (base $target_branch, repo $TARGET_REPO)"
    fi
    
    # Change to the cloned repository directory
    cd "$temp_dir"
    
    local branch_name
    if [ -n "$existing_branch" ]; then
        branch_name="$existing_branch"
        # Already on existing branch from prepare_target_repo
    else
        branch_name="update-sha-refs-$(date +%Y%m%d-%H%M%S)"
        # Create and checkout new branch
        git checkout -b "$branch_name"
    fi
    
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
    if ! git commit -s -m "chore(automation): update Containerfile-downstream SHA references from snapshot

- Updated SHA references for version $version
- Generated from latest snapshot
- Automated update via mtv-releng script"; then
        log_error "Failed to commit changes"
        return 1
    fi
    
    log "Committed changes successfully"
    
    # After rebase: history rewritten → --force-with-lease. After merge fallback: linear merge commit → plain push.
    if [ -n "$existing_branch" ]; then
        if [ "${BUNDLE_SYNC_EXISTING_BRANCH_PUSH_MODE:-rebase}" = "merge" ]; then
            if ! git push origin "$branch_name"; then
                log_error "Failed to push branch $branch_name (merge path; no force push)"
                return 1
            fi
            log "Pushed $branch_name (merged base into PR branch; no force needed)"
        else
            if ! git push --force-with-lease origin "$branch_name"; then
                log_error "Failed to push branch $branch_name with --force-with-lease (needed after rebase)"
                return 1
            fi
            log "Pushed $branch_name with --force-with-lease (rebased onto base)"
        fi
    else
        if ! git push origin "$branch_name"; then
            log_error "Failed to push branch $branch_name"
            return 1
        fi
        log "Pushed branch $branch_name successfully"
    fi
    
    if [ -n "$existing_branch" ]; then
        log_success "Open PR updated successfully (branch $branch_name pushed)"
    else
        # Create PR
        local pr_title="chore(automation): Bundle SHA reference update for $version"
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
    fi
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
    
    unset BUNDLE_SYNC_EXISTING_BRANCH_PUSH_MODE
    
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
    
    if ! extract_sha_references "$snapshot_name" "$version" "$target_branch" > "$temp_sha_stdout" 2> "$temp_sha_stderr"; then
        # Replay to stdout so ./script >>file captures validation/extract logs (not only stderr)
        cat "$temp_sha_stderr"
        log_error "Failed to extract SHA references. Component validation may have failed."
        rm -f "$temp_sha_stdout" "$temp_sha_stderr"
        return 1
    fi
    
    # Replay subprocess diagnostics to stdout (same stream as log); use >>log 2>&1 for log_error/skopeo on stderr
    cat "$temp_sha_stderr"
    
    # Get the JSON from stdout - read entire content, jq can handle multi-line JSON
    sha_mapping=$(cat "$temp_sha_stdout" 2>/dev/null)
    rm -f "$temp_sha_stdout" "$temp_sha_stderr"
    
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

    # Find an existing sync PR for both dry-run and live (dry-run uses it for accurate preview + messages)
    local existing_sync_branch=""
    existing_sync_branch=$(find_existing_sync_pr "$version" "$target_branch") || true
    if [ -n "$existing_sync_branch" ]; then
        if [ "$dry_run" = "true" ]; then
            log "Found existing open sync PR (head $existing_sync_branch → base $target_branch); live run would rebase that head onto the latest base before editing"
        else
            log "Found existing open sync PR (head $existing_sync_branch → base $target_branch); rebasing head onto latest base, then applying SHA updates"
        fi
    else
        if [ "$dry_run" = "true" ]; then
            log "No existing open sync PR with matching title; live run would branch from $target_branch and open a new PR if Containerfile changes are needed"
        else
            log "No existing open sync PR with matching title; will create a new branch and PR if Containerfile changes are needed"
        fi
    fi

    if [ "$dry_run" = "true" ]; then
        log "Proceeding to dry-run preview of Containerfile-downstream SHA updates (raw file via curl; no clone)"
    else
        log "Proceeding to clone, rebase existing PR branch if present, and apply Containerfile-downstream SHA updates"
    fi

    # Update Containerfile-downstream files
    local updated_files
    local update_result
    
    # For both dry run and actual run, we need to capture the output but also display it
    # Use a temporary file to capture the return value and stdout separately
    local temp_result_file="/tmp/bundle_sync_result_$$"
    local temp_stdout_file="/tmp/bundle_sync_stdout_$$"
    
    # Capture stdout (file paths) and stderr (logs) separately.
    # Non-zero exit is normal when SHAs already match (return 1); set -e must not abort before we replay logs and branch on $update_result.
    set +e
    update_containerfile_shas "$sha_mapping" "$dry_run" "$target_branch" "$TEMP_DIR" "$existing_sync_branch" > "$temp_stdout_file" 2> "$temp_result_file"
    update_result=$?
    set -e
    
    # Replay to stdout so ./script >>file includes Containerfile update preview logs
    if [ -s "$temp_result_file" ]; then
        cat "$temp_result_file"
    fi
    
    local dry_run_would_update=""
    dry_run_would_update=$(grep '^BUNDLE_SYNC_DRY_RUN_WOULD_UPDATE=' "$temp_stdout_file" 2>/dev/null | tail -1 | cut -d= -f2)
    
    # The function outputs the file path to stdout (non-dry-run), but we know it should be CONTAINERFILE_PATH
    # If the update was successful, use the known path (simpler and more reliable)
    if [ $update_result -eq 0 ]; then
        # Check if there's a valid path in stdout, otherwise use the default (ignore machine-readable dry-run lines)
        local extracted_path
        extracted_path=$(grep -v '^BUNDLE_SYNC_' "$temp_stdout_file" 2>/dev/null | grep -E "^[a-zA-Z0-9_/.-]+$" | grep -F "$CONTAINERFILE_PATH" | head -1 || true)
        if [ -n "$extracted_path" ] && [[ "$extracted_path" == "$CONTAINERFILE_PATH" ]]; then
            updated_files="$extracted_path"
        else
            # Use the known path - function should output it, but if stdout is corrupted, we know what it is
            updated_files="$CONTAINERFILE_PATH"
        fi
    fi
    
    rm -f "$temp_result_file" "$temp_stdout_file"
    
    if [ "$dry_run" = "true" ]; then
        log "DRY RUN: update_containerfile_shas exit code: $update_result"
        if [ -n "$updated_files" ]; then
            log "DRY RUN: Relative path(s) that a live run would modify in the repo: $updated_files"
        fi
    else
        log "update_containerfile_shas exit code: $update_result"
        log "Paths written in clone when updates applied: '$updated_files'"
    fi
    
    if [ $update_result -eq 0 ]; then
        if [ "$dry_run" = "false" ]; then
            if [ -z "$updated_files" ]; then
                log_error "No updated files path resolved; cannot create or update PR"
                return 1
            fi
            log "Applying changes: git commit and push (and gh pr create or update PR for): $updated_files"
            if ! create_pr "$version" "$target_branch" "$dry_run" "$updated_files" "$TEMP_DIR" "$snapshot_name" "$existing_sync_branch"; then
                log_error "Failed to create or update PR"
                return 1
            fi
        else
            if [ "${dry_run_would_update:-}" = "0" ]; then
                log "DRY RUN: Skipping git commit/push preview (no ARG lines would change; already matches snapshot)"
            elif [ -n "$updated_files" ]; then
                if ! create_pr "$version" "$target_branch" "$dry_run" "$updated_files" "$TEMP_DIR" "$snapshot_name" "$existing_sync_branch"; then
                    log_error "DRY RUN: unexpected failure from create_pr preview"
                    return 1
                fi
            fi
            log "DRY RUN: Preview finished (Containerfile preview via curl; gh pr list used for existing PR detection; no git write operations)"
        fi
    else
        if [ "$dry_run" = "true" ]; then
            log "DRY RUN: update_containerfile_shas reported an error (see messages above)"
        else
            log "Skipping commit and PR (update_containerfile_shas exited $update_result; usually means SHAs already match the snapshot, or a prior step failed—see logs above)"
        fi
    fi
    
    log "Process completed successfully"
}

# Run main function with all arguments
main "$@"

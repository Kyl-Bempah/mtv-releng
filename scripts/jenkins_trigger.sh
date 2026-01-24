#!/usr/bin/env bash

# Jenkins job triggering module
# Handles job triggering, validation, and initial setup

set -euo pipefail

# Source utility functions
source "$(dirname "$0")/util.sh"

# Global variables
declare -A JOB_TRACKING

# Function to load configuration from JSON file
# Returns cluster and matrix mappings in the string format for backward compatibility
load_config_from_file() {
  local config_file="$1"

  if [ ! -f "$config_file" ]; then
    log_error "Configuration file not found: $config_file"
    return 1
  fi

  # Check if jq is available
  if ! command -v jq &>/dev/null; then
    log_error "jq is required to parse JSON configuration files. Please install jq."
    return 1
  fi

  # Validate JSON
  if ! jq empty "$config_file" 2>/dev/null; then
    log_error "Invalid JSON in configuration file: $config_file"
    return 1
  fi

  # Extract cluster mapping
  local cluster_map=""
  local matrix_map=""
  local job_suffix=""
  local iib_map=""

  # Check for combined OCP+suffix cluster mapping (most specific)
  local combined_clusters=$(jq -r '.clusters.by_ocp_and_suffix // empty' "$config_file" 2>/dev/null)
  if [ -n "$combined_clusters" ] && [ "$combined_clusters" != "null" ]; then
    # Convert JSON to string format: "4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,..."
    local ocp_versions=$(echo "$combined_clusters" | jq -r 'keys[]' 2>/dev/null)
    local cluster_parts=()
    for ocp_ver in $ocp_versions; do
      local suffixes=$(echo "$combined_clusters" | jq -r ".[\"$ocp_ver\"] | keys[]" 2>/dev/null)
      for suffix in $suffixes; do
        local cluster=$(echo "$combined_clusters" | jq -r ".[\"$ocp_ver\"][\"$suffix\"]" 2>/dev/null)
        cluster_parts+=("${ocp_ver}:${suffix}:${cluster}")
      done
    done
    if [ ${#cluster_parts[@]} -gt 0 ]; then
      cluster_map=$(
        IFS=','
        echo "${cluster_parts[*]}"
      )
    fi
  fi

  # If no combined mapping, check for OCP version mapping
  if [ -z "$cluster_map" ]; then
    local ocp_clusters=$(jq -r '.clusters.by_ocp_version // empty' "$config_file" 2>/dev/null)
    if [ -n "$ocp_clusters" ] && [ "$ocp_clusters" != "null" ]; then
      local ocp_versions=$(echo "$ocp_clusters" | jq -r 'keys[]' 2>/dev/null)
      local cluster_parts=()
      for ocp_ver in $ocp_versions; do
        local cluster=$(echo "$ocp_clusters" | jq -r ".[\"$ocp_ver\"]" 2>/dev/null)
        cluster_parts+=("${ocp_ver}:${cluster}")
      done
      if [ ${#cluster_parts[@]} -gt 0 ]; then
        cluster_map=$(
          IFS=','
          echo "${cluster_parts[*]}"
        )
      fi
    fi
  fi

  # If still no mapping, check for suffix mapping
  if [ -z "$cluster_map" ]; then
    local suffix_clusters=$(jq -r '.clusters.by_suffix // empty' "$config_file" 2>/dev/null)
    if [ -n "$suffix_clusters" ] && [ "$suffix_clusters" != "null" ]; then
      local suffixes=$(echo "$suffix_clusters" | jq -r 'keys[]' 2>/dev/null)
      local cluster_parts=()
      for suffix in $suffixes; do
        local cluster=$(echo "$suffix_clusters" | jq -r ".[\"$suffix\"]" 2>/dev/null)
        cluster_parts+=("${suffix}:${cluster}")
      done
      if [ ${#cluster_parts[@]} -gt 0 ]; then
        cluster_map=$(
          IFS=','
          echo "${cluster_parts[*]}"
        )
      fi
    fi
  fi

  # If still no mapping, use default
  if [ -z "$cluster_map" ]; then
    cluster_map=$(jq -r '.clusters.default // "qemtv-01"' "$config_file" 2>/dev/null)
  fi

  # Extract matrix type mapping
  local matrix_by_suffix=$(jq -r '.matrix_types.by_suffix // empty' "$config_file" 2>/dev/null)
  if [ -n "$matrix_by_suffix" ] && [ "$matrix_by_suffix" != "null" ]; then
    local suffixes=$(echo "$matrix_by_suffix" | jq -r 'keys[]' 2>/dev/null)
    local matrix_parts=()
    for suffix in $suffixes; do
      local matrix=$(echo "$matrix_by_suffix" | jq -r ".[\"$suffix\"]" 2>/dev/null)
      matrix_parts+=("${suffix}:${matrix}")
    done
    if [ ${#matrix_parts[@]} -gt 0 ]; then
      matrix_map=$(
        IFS=','
        echo "${matrix_parts[*]}"
      )
    fi
  fi

  # If no suffix mapping, use default
  if [ -z "$matrix_map" ]; then
    matrix_map=$(jq -r '.matrix_types.default // "RELEASE"' "$config_file" 2>/dev/null)
  fi

  # Extract job suffixes
  local suffixes_config=$(jq -r '.job_suffixes.common // .job_suffixes.default // empty' "$config_file" 2>/dev/null)
  if [ -n "$suffixes_config" ] && [ "$suffixes_config" != "null" ]; then
    # Handle array format
    if echo "$suffixes_config" | jq -e '. | type == "array"' &>/dev/null; then
      job_suffix=$(echo "$suffixes_config" | jq -r 'join(",")' 2>/dev/null)
    else
      job_suffix="$suffixes_config"
    fi
  fi

  # Extract IIB mapping
  local combined_iibs=$(jq -r '.iibs.by_ocp_and_suffix // empty' "$config_file" 2>/dev/null)
  if [ -n "$combined_iibs" ] && [ "$combined_iibs" != "null" ]; then
    # Convert JSON to string format: "4.19:gate:forklift-fbc-prod-v420:on-pr-abc123,..."
    local ocp_versions=$(echo "$combined_iibs" | jq -r 'keys[]' 2>/dev/null)
    local iib_parts=()
    for ocp_ver in $ocp_versions; do
      local suffixes=$(echo "$combined_iibs" | jq -r ".[\"$ocp_ver\"] | keys[]" 2>/dev/null)
      for suffix in $suffixes; do
        local iib_val=$(echo "$combined_iibs" | jq -r ".[\"$ocp_ver\"][\"$suffix\"]" 2>/dev/null)
        iib_parts+=("${ocp_ver}:${suffix}:${iib_val}")
      done
    done
    if [ ${#iib_parts[@]} -gt 0 ]; then
      iib_map=$(
        IFS=','
        echo "${iib_parts[*]}"
      )
    fi
  fi

  # If no combined mapping, check for OCP version mapping
  if [ -z "$iib_map" ]; then
    local ocp_iibs=$(jq -r '.iibs.by_ocp_version // empty' "$config_file" 2>/dev/null)
    if [ -n "$ocp_iibs" ] && [ "$ocp_iibs" != "null" ]; then
      local ocp_versions=$(echo "$ocp_iibs" | jq -r 'keys[]' 2>/dev/null)
      local iib_parts=()
      for ocp_ver in $ocp_versions; do
        local iib_val=$(echo "$ocp_iibs" | jq -r ".[\"$ocp_ver\"]" 2>/dev/null)
        iib_parts+=("${ocp_ver}:${iib_val}")
      done
      if [ ${#iib_parts[@]} -gt 0 ]; then
        iib_map=$(
          IFS=','
          echo "${iib_parts[*]}"
        )
      fi
    fi
  fi

  # If still no mapping, check for suffix mapping
  if [ -z "$iib_map" ]; then
    local suffix_iibs=$(jq -r '.iibs.by_suffix // empty' "$config_file" 2>/dev/null)
    if [ -n "$suffix_iibs" ] && [ "$suffix_iibs" != "null" ]; then
      local suffixes=$(echo "$suffix_iibs" | jq -r 'keys[]' 2>/dev/null)
      local iib_parts=()
      for suffix in $suffixes; do
        local iib_val=$(echo "$suffix_iibs" | jq -r ".[\"$suffix\"]" 2>/dev/null)
        iib_parts+=("${suffix}:${iib_val}")
      done
      if [ ${#iib_parts[@]} -gt 0 ]; then
        iib_map=$(
          IFS=','
          echo "${iib_parts[*]}"
        )
      fi
    fi
  fi

  # Output in format: CLUSTER_MAP|MATRIX_MAP|JOB_SUFFIX|IIB_MAP
  echo "${cluster_map}|${matrix_map}|${job_suffix}|${iib_map}"
  return 0
}

# Function to get cluster name for a specific OCP version and job suffix
# Supports multiple mapping formats:
#   - Single value: "qemtv-01" (applies to all)
#   - Suffix mapping: "gate:qemtv-01,non-gate:qemtv-02" (per suffix)
#   - OCP mapping: "4.19:qemtv-01,4.20:qemtv-02" (per OCP version)
#   - Combined mapping: "4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03" (per OCP and suffix)
get_cluster_for_suffix() {
  local cluster_param="$1"
  local openshift_version="$2"
  local job_suffix="$3"
  local default_cluster="${4:-qemtv-01}"

  # If cluster_param is empty, use default
  if [ -z "$cluster_param" ]; then
    echo "$default_cluster"
    return 0
  fi

  # Check if it's a mapping format (contains colon)
  if [[ "$cluster_param" =~ : ]]; then
    IFS=',' read -ra CLUSTER_MAPPINGS <<<"$cluster_param"

    # First, check for combined format (ocp-version:suffix:cluster) - most specific
    for mapping in "${CLUSTER_MAPPINGS[@]}"; do
      echo $mapping
      mapping=$(echo "$mapping" | xargs)

      # Count colons to determine format
      local colon_count=$(echo "$mapping" | tr -cd ':' | wc -c | xargs)

      if [ "$colon_count" -eq 2 ]; then
        # Combined format: "4.19:gate:qemtv-01"
        local ocp_part="${mapping%%:*}"
        local remaining="${mapping#*:}"
        local suffix_part="${remaining%%:*}"
        local cluster_part="${remaining#*:}"

        # Trim whitespace
        ocp_part=$(echo "$ocp_part" | xargs)
        suffix_part=$(echo "$suffix_part" | xargs)
        cluster_part=$(echo "$cluster_part" | xargs)

        # Remove "ocp-" prefix if present for comparison
        local ocp_clean="${ocp_part#ocp-}"
        local version_clean="${openshift_version}"

        if [ "$ocp_clean" = "$version_clean" ] && [ "$suffix_part" = "$job_suffix" ]; then
          echo "$cluster_part"
          return 0
        fi
      fi
    done

    # Second, check for OCP version format (ocp-version:cluster) - OCP-specific
    for mapping in "${CLUSTER_MAPPINGS[@]}"; do
      mapping=$(echo "$mapping" | xargs)
      local colon_count=$(echo "$mapping" | tr -cd ':' | wc -c | xargs)

      if [ "$colon_count" -eq 1 ]; then
        local key_part="${mapping%%:*}"
        local cluster_part="${mapping#*:}"

        # Trim whitespace
        key_part=$(echo "$key_part" | xargs)
        cluster_part=$(echo "$cluster_part" | xargs)

        # Check if key_part looks like an OCP version (starts with number or "ocp-")
        if [[ "$key_part" =~ ^[0-9] ]] || [[ "$key_part" =~ ^ocp- ]]; then
          # OCP version format: "4.19:qemtv-01" or "ocp-4.19:qemtv-01"
          local ocp_clean="${key_part#ocp-}"
          local version_clean="${openshift_version}"

          if [ "$ocp_clean" = "$version_clean" ]; then
            echo "$cluster_part"
            return 0
          fi
        fi
      fi
    done

    # Third, check for suffix format (suffix:cluster) - suffix-specific
    for mapping in "${CLUSTER_MAPPINGS[@]}"; do
      mapping=$(echo "$mapping" | xargs)
      local colon_count=$(echo "$mapping" | tr -cd ':' | wc -c | xargs)

      if [ "$colon_count" -eq 1 ]; then
        local key_part="${mapping%%:*}"
        local cluster_part="${mapping#*:}"

        # Trim whitespace
        key_part=$(echo "$key_part" | xargs)
        cluster_part=$(echo "$cluster_part" | xargs)

        # Check if key_part is NOT an OCP version (doesn't start with number or "ocp-")
        if [[ ! "$key_part" =~ ^[0-9] ]] && [[ ! "$key_part" =~ ^ocp- ]]; then
          # Suffix format: "gate:qemtv-01"
          if [ "$key_part" = "$job_suffix" ]; then
            echo "$cluster_part"
            return 0
          fi
        fi
      fi
    done

    # No mapping found, use default
    log_warning "No cluster mapping found for OCP version '$openshift_version' and suffix '$job_suffix', using default: $default_cluster"
    echo "$default_cluster"
    return 0
  else
    # Single value format - applies to all
    echo "$cluster_param"
    return 0
  fi
}

# Function to get IIB value for a specific OCP version and job suffix
# Supports multiple mapping formats (same as cluster mapping):
#   - Single value: "forklift-fbc-prod-v420:on-pr-abc123" (applies to all)
#   - Suffix mapping: "gate:forklift-fbc-prod-v420:on-pr-abc123,non-gate:forklift-fbc-prod-v420:on-pr-xyz789" (per suffix)
#   - OCP mapping: "4.19:forklift-fbc-prod-v420:on-pr-abc123,4.20:forklift-fbc-prod-v420:on-pr-xyz789" (per OCP version)
#   - Combined mapping: "4.19:gate:forklift-fbc-prod-v420:on-pr-abc123,4.19:non-gate:forklift-fbc-prod-v420:on-pr-xyz789" (per OCP and suffix)
get_iib_for_suffix() {
  local iib_param="$1"
  local openshift_version="$2"
  local job_suffix="$3"
  local default_iib="${4:-}"

  # If iib_param is empty, use default
  if [ -z "$iib_param" ]; then
    echo "$default_iib"
    return 0
  fi

  # Check if it's a mapping format (contains colon)
  if [[ "$iib_param" =~ : ]]; then
    IFS=',' read -ra IIB_MAPPINGS <<<"$iib_param"

    # First, check for combined format (ocp-version:suffix:iib) - most specific
    for mapping in "${IIB_MAPPINGS[@]}"; do
      mapping=$(echo "$mapping" | xargs)

      # Count colons to determine format
      local colon_count=$(echo "$mapping" | tr -cd ':' | wc -c | xargs)

      if [ "$colon_count" -eq 2 ]; then
        # Combined format: "4.19:gate:forklift-fbc-prod-v420:on-pr-abc123"
        local ocp_part="${mapping%%:*}"
        local remaining="${mapping#*:}"
        local suffix_part="${remaining%%:*}"
        local iib_part="${remaining#*:}"

        # Trim whitespace
        ocp_part=$(echo "$ocp_part" | xargs)
        suffix_part=$(echo "$suffix_part" | xargs)
        iib_part=$(echo "$iib_part" | xargs)

        # Remove "ocp-" prefix if present for comparison
        local ocp_clean="${ocp_part#ocp-}"
        local version_clean="${openshift_version}"

        if [ "$ocp_clean" = "$version_clean" ] && [ "$suffix_part" = "$job_suffix" ]; then
          echo "$iib_part"
          return 0
        fi
      fi
    done

    # Second, check for OCP version format (ocp-version:iib) - OCP-specific
    for mapping in "${IIB_MAPPINGS[@]}"; do
      mapping=$(echo "$mapping" | xargs)
      local colon_count=$(echo "$mapping" | tr -cd ':' | wc -c | xargs)

      if [ "$colon_count" -eq 1 ]; then
        local key_part="${mapping%%:*}"
        local iib_part="${mapping#*:}"

        # Trim whitespace
        key_part=$(echo "$key_part" | xargs)
        iib_part=$(echo "$iib_part" | xargs)

        # Check if key_part looks like an OCP version (starts with number or "ocp-")
        if [[ "$key_part" =~ ^[0-9] ]] || [[ "$key_part" =~ ^ocp- ]]; then
          # OCP version format: "4.19:forklift-fbc-prod-v420:on-pr-abc123"
          local ocp_clean="${key_part#ocp-}"
          local version_clean="${openshift_version}"

          if [ "$ocp_clean" = "$version_clean" ]; then
            echo "$iib_part"
            return 0
          fi
        fi
      fi
    done

    # Third, check for suffix format (suffix:iib) - suffix-specific
    for mapping in "${IIB_MAPPINGS[@]}"; do
      mapping=$(echo "$mapping" | xargs)
      local colon_count=$(echo "$mapping" | tr -cd ':' | wc -c | xargs)

      if [ "$colon_count" -eq 1 ]; then
        local key_part="${mapping%%:*}"
        local iib_part="${mapping#*:}"

        # Trim whitespace
        key_part=$(echo "$key_part" | xargs)
        iib_part=$(echo "$iib_part" | xargs)

        # Check if key_part is NOT an OCP version (doesn't start with number or "ocp-")
        if [[ ! "$key_part" =~ ^[0-9] ]] && [[ ! "$key_part" =~ ^ocp- ]]; then
          # Suffix format: "gate:forklift-fbc-prod-v420:on-pr-abc123"
          if [ "$key_part" = "$job_suffix" ]; then
            echo "$iib_part"
            return 0
          fi
        fi
      fi
    done

    # No mapping found, use default
    log_warning "No IIB mapping found for OCP version '$openshift_version' and suffix '$job_suffix', using default: $default_iib"
    echo "$default_iib"
    return 0
  else
    # Single value format - applies to all
    echo "$iib_param"
    return 0
  fi
}

# Function to get matrix type for a specific job suffix
# Supports both single value (applies to all) and mapping format (suffix:type,suffix:type)
get_matrix_type_for_suffix() {
  local matrix_type_param="$1"
  local job_suffix="$2"
  local default_matrix_type="${3:-RELEASE}"

  # If matrix_type_param is empty, use default
  if [ -z "$matrix_type_param" ]; then
    echo "$default_matrix_type"
    return 0
  fi

  # Check if it's a mapping format (contains colon)
  if [[ "$matrix_type_param" =~ : ]]; then
    # Parse mapping format: "gate:RELEASE,non-gate:FULL"
    IFS=',' read -ra MATRIX_MAPPINGS <<<"$matrix_type_param"
    for mapping in "${MATRIX_MAPPINGS[@]}"; do
      # Trim whitespace
      mapping=$(echo "$mapping" | xargs)
      local suffix_part="${mapping%%:*}"
      local type_part="${mapping#*:}"
      # Trim whitespace from parts
      suffix_part=$(echo "$suffix_part" | xargs)
      type_part=$(echo "$type_part" | xargs)

      if [ "$suffix_part" = "$job_suffix" ]; then
        echo "$type_part"
        return 0
      fi
    done
    # No mapping found for this suffix, use default
    log_warning "No matrix type mapping found for suffix '$job_suffix', using default: $default_matrix_type"
    echo "$default_matrix_type"
    return 0
  else
    # Single value format - applies to all suffixes
    echo "$matrix_type_param"
    return 0
  fi
}

# Function to extract job number from Jenkins response
extract_job_number() {
  local response="$1"
  local location_header

  # Extract Location header, handling both \r\n and \n line endings
  location_header=$(echo "$response" | grep -i '^Location:' | head -1 | tr -d '\r')

  if [ -z "$location_header" ]; then
    return 1
  fi

  # Extract the URL from the Location header
  local location_url
  location_url=$(echo "$location_header" | awk '{print $2}' | tr -d '\r')

  if [ -z "$location_url" ]; then
    return 1
  fi

  # Handle direct job URLs: /job/jobname/123/
  if echo "$location_url" | grep -qE "/job/[^/]+/[0-9]+/?$"; then
    echo "$location_url" | grep -oE '/job/[^/]+/[0-9]+' | grep -oE '[0-9]+$'
  # Handle queue item URLs: /queue/item/123
  elif echo "$location_url" | grep -qE "/queue/item/[0-9]+/?$"; then
    local queue_item
    queue_item=$(echo "$location_url" | grep -oE '/queue/item/[0-9]+' | grep -oE '[0-9]+$')
    if [ -n "$queue_item" ]; then
      echo "QUEUED_${queue_item}"
    else
      return 1
    fi
  # Handle job URLs without build number: /job/jobname/ (job was queued)
  elif echo "$location_url" | grep -qE "/job/[^/]+/?$"; then
    # Extract job name from URL
    local job_name
    job_name=$(echo "$location_url" | grep -oE '/job/[^/]+' | sed 's|/job/||')

    # For buildWithParameters, we should get a queue item, but if we get a job URL,
    # it means the job was triggered but we need to wait for it to start
    echo "PENDING_${job_name}"
  else
    log_error "Unknown location URL format: $location_url"
    return 1
  fi
}

# Function to validate build parameters
validate_build_parameters() {
  local job_name="$1"
  local build_number="$2"
  local expected_iib="$3"
  local expected_mtv_version="$4"
  local expected_ocp_version="$5"

  local build_url="${JENKINS_BASE_URL}/job/${job_name}/${build_number}/api/json"
  local build_response

  if ! build_response=$(jenkins_api_call "$build_url" ""); then
    log_warning "Failed to get build info for ${job_name}#${build_number}" >&2
    return 1
  fi

  local actual_iib
  actual_iib=$(echo "$build_response" | jq -r '.actions[] | select(.parameters) | .parameters[] | select(.name=="IIB_NO") | .value // empty' 2>/dev/null)

  if [ -z "$actual_iib" ] || [ "$actual_iib" = "null" ]; then
    log_warning "No IIB parameter found in build ${job_name}#${build_number}" >&2
    return 1
  fi

  if [ "$actual_iib" != "$expected_iib" ]; then
    log_warning "IIB mismatch: expected '$expected_iib', got '$actual_iib'" >&2
    return 1
  fi

  return 0
}

# Function to trigger a Jenkins job
trigger_jenkins_job() {
  local openshift_version="$1"
  local iib="$2"
  local mtv_version="$3"
  local rc="$4"
  local cluster_name="${5:-qemtv-01}" # Default to qemtv-01 if not provided
  local job_suffix="${6:-gate}"       # Default to "gate" for backward compatibility
  local matrix_type="${7:-RELEASE}"   # Default to "RELEASE" for backward compatibility

  # Variable creation for XY version (drop trailing .z)
  local mtv_xy_version
  mtv_xy_version=$(echo "$mtv_version" | awk -F. '{print $1"."$2}')

  local job_name="mtv-${mtv_xy_version}-ocp-${openshift_version}-test-release-${job_suffix}"
  local job_url="${JENKINS_BASE_URL}/job/${job_name}"

  log_info "Triggering job for OCP version: $openshift_version (cluster: $cluster_name, job_suffix: $job_suffix, matrix_type: $matrix_type)"

  # Record trigger timestamp BEFORE triggering the job
  local trigger_timestamp=$(date +%s)000 # Convert to milliseconds

  # Trigger the job using direct curl with --data-urlencode (most readable approach)
  local response
  if ! response=$(curl -s -S -f -i --insecure --connect-timeout 15 --max-time 60 -X POST \
    --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
    --data-urlencode "BRANCH=master" \
    --data-urlencode "CLUSTER_NAME=${cluster_name}" \
    --data-urlencode "DEPLOY_MTV=true" \
    --data-urlencode "GIT_BRANCH=main" \
    --data-urlencode "IIB_NO=${iib}" \
    --data-urlencode "MATRIX_TYPE=${matrix_type}" \
    --data-urlencode "MTV_API_TEST_GIT_USER=RedHatQE" \
    --data-urlencode "MTV_SOURCE=KONFLUX" \
    --data-urlencode "MTV_VERSION=${mtv_version}" \
    --data-urlencode "MTV_XY_VERSION=${mtv_xy_version}" \
    --data-urlencode "NFS_SERVER_IP=f02-h06-000-r640.rdu2.scalelab.redhat.com" \
    --data-urlencode "NFS_SHARE_PATH=/home/nfsshare" \
    --data-urlencode "OCP_VERSION=${openshift_version}" \
    --data-urlencode "OCP_XY_VERSION=${openshift_version}" \
    --data-urlencode "OPENSHIFT_PYTHON_WRAPPER_GIT_BRANCH=main" \
    --data-urlencode "PYTEST_EXTRA_PARAMS=--tc=release_test:true --tc=target_ocp_version:${openshift_version}" \
    --data-urlencode "RC=${rc}" \
    --data-urlencode "REMOTE_CLUSTER_NAME=${cluster_name}" \
    --data-urlencode "RUN_TESTS_IN_PARALLEL=false" \
    --data-urlencode "CLEAN_CATALOG=true" \
    "${job_url}/buildWithParameters" 2>&1); then
    log_error "Failed to trigger job: $response"
    return 1
  fi

  # Extract job number from response
  local job_number
  if ! job_number=$(extract_job_number "$response"); then
    log_error "Failed to extract job number from Jenkins response"
    log_error "Response headers: $(echo "$response" | head -10)"
    if [ "${DEBUG:-false}" = "true" ]; then
      log_error "Full response: $response"
    fi
    return 1
  fi

  # Validate job number format
  if [[ ! "$job_number" =~ ^(QUEUED_[0-9]+|PENDING_.+|[0-9]+)$ ]]; then
    log_error "Invalid job number format: $job_number"
    return 1
  fi

  # If job is queued, wait for it to resolve to actual build number
  if [[ "$job_number" =~ ^QUEUED_ ]]; then
    local queue_item="${job_number#QUEUED_}"
    log_info "Job queued with queue item ${queue_item}, waiting for build number..." >&2

    local resolved_build_number
    if resolved_build_number=$(resolve_queue_item_to_build "$job_name" "$queue_item" "$trigger_timestamp"); then
      job_number="$resolved_build_number"
      log_success "Queue item resolved to build number: $job_number" >&2
    else
      log_warning "Failed to resolve queue item to build number, will use queue item ID: $job_number" >&2
      # Continue with QUEUED_ prefix - watch script will handle resolution later
    fi
  elif [[ "$job_number" =~ ^PENDING_ ]]; then
    # For PENDING jobs, try to get latest build and validate it
    # Use unified function to resolve (polling mode)
    local resolved_build_number
    if resolved_build_number=$(resolve_pending_job_to_build "$job_name" "$trigger_timestamp"); then
      job_number="$resolved_build_number"
      log_success "Pending job resolved to build number: $job_number" >&2
    else
      log_warning "Failed to resolve PENDING job to build number, will use PENDING status" >&2
    fi
  fi

  # Construct appropriate URL based on job number type
  local job_url_full
  if [[ "$job_number" =~ ^(PENDING_|QUEUED_) ]]; then
    # For pending/queued jobs, use job URL without build number
    job_url_full="${job_url}/"
  else
    # For regular build numbers, include the build number in URL
    job_url_full="${job_url}/${job_number}/"
  fi

  # Store job tracking info with trigger timestamp
  JOB_TRACKING["$job_name"]="${job_number}|${job_url_full}|${openshift_version}|${trigger_timestamp}"

  log_success "Job triggered successfully. Job number: $job_number"
  return 0
}

# Function to trigger all jobs
trigger_all_jobs() {
  local iib="$1"
  local mtv_version="$2"
  local ocp_versions="$3"
  local rc="$4"
  local cluster_name="${5:-qemtv-01}" # Default to qemtv-01 if not provided
  local job_suffix="${6:-gate}"       # Default to "gate" for backward compatibility (can be comma-separated)
  local matrix_type="${7:-RELEASE}"   # Default to "RELEASE" for backward compatibility
  local iib_map="${8:-}"              # Optional IIB mapping (if empty, uses single iib value for all)

  # Convert comma-separated OCP versions to array
  IFS=',' read -ra OCP_VERSIONS_ARRAY <<<"$ocp_versions"

  # Convert comma-separated job suffixes to array
  IFS=',' read -ra JOB_SUFFIX_ARRAY <<<"$job_suffix"

  # Trigger jobs for each combination of OCP version and job suffix
  for openshift_version in "${OCP_VERSIONS_ARRAY[@]}"; do
    # Trim whitespace
    openshift_version=$(echo "$openshift_version" | xargs)

    for suffix in "${JOB_SUFFIX_ARRAY[@]}"; do
      # Trim whitespace
      suffix=$(echo "$suffix" | xargs)

      # Get cluster name for this specific OCP version and suffix
      local suffix_cluster
      suffix_cluster=$(get_cluster_for_suffix "$cluster_name" "$openshift_version" "$suffix" "qemtv-01")

      # Get matrix type for this specific suffix
      local suffix_matrix_type
      suffix_matrix_type=$(get_matrix_type_for_suffix "$matrix_type" "$suffix" "RELEASE")

      # Get IIB value for this specific OCP version and suffix (if mapping provided)
      local suffix_iib
      if [ -n "$iib_map" ]; then
        suffix_iib=$(get_iib_for_suffix "$iib_map" "$openshift_version" "$suffix" "$iib")
      else
        suffix_iib="$iib"
      fi

      if ! trigger_jenkins_job "$openshift_version" "$suffix_iib" "$mtv_version" "$rc" "$suffix_cluster" "$suffix" "$suffix_matrix_type"; then
        log_error "Failed to trigger job for OCP version: $openshift_version, job suffix: $suffix, cluster: $suffix_cluster"
        return 1
      fi
    done
  done

  log_success "All jobs triggered successfully. Waiting for completion..."
  echo
  return 0
}

# Function to export job tracking data for handoff to next stage
export_job_data() {
  local output_file="${1:-job_tracking.json}"

  echo "{" >"$output_file"
  echo "  \"jobs\": [" >>"$output_file"

  local first=true
  for job_name in "${!JOB_TRACKING[@]}"; do
    if [ "$first" = true ]; then
      first=false
    else
      echo "," >>"$output_file"
    fi

    local job_info="${JOB_TRACKING[$job_name]}"
    local parsed_info=$(parse_job_info "$job_info")
    local job_number="${parsed_info%%|*}"
    local remaining="${parsed_info#*|}"
    local job_url="${remaining%%|*}"

    # Extract OCP version using shared function
    local ocp_version=$(extract_ocp_version_from_parsed_info "$remaining")

    echo "    {" >>"$output_file"
    echo "      \"job_name\": \"$job_name\"," >>"$output_file"
    echo "      \"job_number\": \"$job_number\"," >>"$output_file"
    echo "      \"job_url\": \"$job_url\"," >>"$output_file"
    echo "      \"ocp_version\": \"$ocp_version\"" >>"$output_file"
    echo -n "    }" >>"$output_file"
  done

  echo "" >>"$output_file"
  echo "  ]" >>"$output_file"
  echo "}" >>"$output_file"

  log_success "Job tracking data exported to: $output_file"
}

# Standalone execution support
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # Script is being run directly, not sourced

  case "${1:-}" in
  "trigger")
    if [ $# -lt 5 ] || [ $# -gt 9 ]; then
      echo "Usage: $0 trigger <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME] [JOB_SUFFIX] [MATRIX_TYPE] [IIB_MAP]"
      echo ""
      echo "Note: You can use environment variables or config files:"
      echo "  JENKINS_CONFIG_FILE - Path to JSON config file (use '@path' or set this env var)"
      echo "  JENKINS_CLUSTER_MAP - Cluster mapping (overrides CLUSTER_NAME if not provided)"
      echo "  JENKINS_JOB_SUFFIX  - Job suffix (overrides JOB_SUFFIX if not provided)"
      echo "  JENKINS_MATRIX_MAP  - Matrix type mapping (overrides MATRIX_TYPE if not provided)"
      echo "  JENKINS_IIB_MAP     - IIB mapping (overrides IIB_MAP if not provided)"
      exit 1
    fi
    # Check if CLUSTER_NAME is a config file reference (starts with @)
    cluster_arg="${6:-}"
    suffix_arg="${7:-}"
    matrix_arg="${8:-}"
    iib_map_arg="${9:-}"

    # Check for environment variable pointing to config file
    if [ -z "$cluster_arg" ] && [ -n "${JENKINS_CONFIG_FILE:-}" ]; then
      cluster_arg="@${JENKINS_CONFIG_FILE}"
    fi

    # If cluster_arg starts with @, it's a config file reference
    if [[ "$cluster_arg" =~ ^@ ]]; then
      config_file="${cluster_arg#@}"
      # Expand environment variables in path
      config_file=$(eval echo "$config_file")
      # Expand ~ and resolve relative paths
      config_file="${config_file/#\~/$HOME}"
      if [[ ! "$config_file" =~ ^/ ]]; then
        # Relative path - resolve from script directory
        config_file="$(dirname "$0")/$config_file"
      fi

      # Load configuration from file
      config_data=""
      if ! config_data=$(load_config_from_file "$config_file"); then
        echo "Error: Failed to load configuration from: $config_file" >&2
        exit 1
      fi

      # Parse config data: CLUSTER_MAP|MATRIX_MAP|JOB_SUFFIX|IIB_MAP
      IFS='|' read -r cluster_arg matrix_arg suffix_arg iib_map_from_config <<<"$config_data"

      # Override with explicit arguments if provided
      suffix_arg="${7:-$suffix_arg}"
      matrix_arg="${8:-$matrix_arg}"
      iib_map_arg="${9:-${iib_map_from_config:-}}"
    else
      # Use environment variables or defaults
      cluster_arg="${cluster_arg:-${JENKINS_CLUSTER_MAP:-qemtv-01}}"
      suffix_arg="${suffix_arg:-${JENKINS_JOB_SUFFIX:-gate}}"
      matrix_arg="${matrix_arg:-${JENKINS_MATRIX_MAP:-RELEASE}}"
      iib_map_arg="${iib_map_arg:-${JENKINS_IIB_MAP:-}}"
    fi

    trigger_all_jobs "$2" "$3" "$4" "$5" "$cluster_arg" "$suffix_arg" "$matrix_arg" "$iib_map_arg"
    export_job_data "job_tracking.json"
    ;;
  "import")
    if [ $# -ne 2 ]; then
      echo "Usage: $0 import <job_data_file>"
      exit 1
    fi
    import_job_data "$2"
    ;;
  "export")
    export_job_data "${2:-job_tracking.json}"
    ;;
  *)
    echo "Usage: $0 {trigger|import|export} [args...]"
    echo
    echo "Commands:"
    echo "  trigger <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME] [JOB_SUFFIX] [MATRIX_TYPE] [IIB_MAP]  - Trigger jobs and export data"
    echo "  import <job_data_file>                                         - Import job data from file"
    echo "  export [output_file]                                           - Export current job data"
    echo
    echo "Arguments:"
    echo "  CLUSTER_NAME: Jenkins cluster name (default: 'qemtv-01')"
    echo "               - Single value: applies to all (e.g., 'qemtv-01')"
    echo "               - Suffix mapping: per job suffix (e.g., 'gate:qemtv-01,non-gate:qemtv-02')"
    echo "               - OCP mapping: per OCP version (e.g., '4.19:qemtv-01,4.20:qemtv-02')"
    echo "               - Combined mapping: per OCP and suffix (e.g., '4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03')"
    echo "  JOB_SUFFIX: Job name suffix (default: 'gate', can be comma-separated, e.g., 'gate', 'non-gate', 'gate,non-gate')"
    echo "  MATRIX_TYPE: Matrix type (default: 'RELEASE')"
    echo "               - Single value: applies to all job suffixes (e.g., 'RELEASE', 'FULL', 'STAGE', 'TIER1')"
    echo "               - Mapping format: different matrix types per suffix (e.g., 'gate:RELEASE,non-gate:FULL')"
    echo "  IIB_MAP: IIB mapping (optional, if not provided, uses single IIB value for all jobs)"
    echo "          - Single value: applies to all (same as IIB argument)"
    echo "          - Suffix mapping: per job suffix (e.g., 'gate:forklift-fbc-prod-v420:on-pr-abc123,non-gate:forklift-fbc-prod-v420:on-pr-xyz789')"
    echo "          - OCP mapping: per OCP version (e.g., '4.19:forklift-fbc-prod-v420:on-pr-abc123,4.20:forklift-fbc-prod-v420:on-pr-xyz789')"
    echo "          - Combined mapping: per OCP and suffix (e.g., '4.19:gate:forklift-fbc-prod-v420:on-pr-abc123,4.19:non-gate:forklift-fbc-prod-v420:on-pr-xyz789')"
    echo
    echo "Examples:"
    echo "  # Basic usage"
    echo "  $0 trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'"
    echo ""
    echo "  # Using environment variables for cleaner calls"
    echo "  export JENKINS_CLUSTER_MAP='4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03,4.20:non-gate:qemtv-04'"
    echo "  export JENKINS_MATRIX_MAP='gate:RELEASE,non-gate:FULL'"
    echo "  $0 trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.19,4.20' 'false' '' 'gate,non-gate'"
    echo ""
    echo "  # Inline arguments (verbose)"
    echo "  $0 trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.19,4.20' 'false' \\"
    echo "    '4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03,4.20:non-gate:qemtv-04' \\"
    echo "    'gate,non-gate' 'gate:RELEASE,non-gate:FULL'"
    echo ""
    echo "  # Different IIB values per job"
    echo "  $0 trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.19,4.20' 'false' 'qemtv-01' 'gate,non-gate' 'RELEASE' \\"
    echo "    'gate:forklift-fbc-prod-v420:on-pr-abc123,non-gate:forklift-fbc-prod-v420:on-pr-xyz789'"
    echo "  $0 import job_tracking.json"
    echo "  $0 export my_jobs.json"
    exit 1
    ;;
  esac
fi

# Export functions and variables for use by other modules
export -f validate_build_parameters
export -f extract_job_number
export -f trigger_jenkins_job
export -f trigger_all_jobs
export -f export_job_data
export -f load_config_from_file
export -f get_iib_for_suffix
export JOB_TRACKING
export JENKINS_BASE_URL

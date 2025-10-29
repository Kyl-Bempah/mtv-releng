#!/bin/bash

# Jenkins job triggering module
# Handles job triggering, validation, and initial setup

set -euo pipefail

# Source utility functions
source "$(dirname "$0")/util.sh"

# Global variables
declare -A JOB_TRACKING

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
    local cluster_name="${5:-qemtv-01}"  # Default to qemtv-01 if not provided
    
    # Variable creation for XY version (drop trailing .z)
    local mtv_xy_version
    mtv_xy_version=$(echo "$mtv_version" | awk -F. '{print $1"."$2}')
    
    local job_name="mtv-${mtv_xy_version}-ocp-${openshift_version}-test-release-gate"
    local job_url="${JENKINS_BASE_URL}/job/${job_name}"
    
    log_info "Triggering job for OCP version: $openshift_version (cluster: $cluster_name)"
    
    # Record trigger timestamp BEFORE triggering the job
    local trigger_timestamp=$(date +%s)000  # Convert to milliseconds
    
    # Trigger the job using direct curl with --data-urlencode (most readable approach)
    local response
    if ! response=$(curl -s -S -f -i --insecure --connect-timeout 15 --max-time 60 -X POST \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        --data-urlencode "BRANCH=master" \
        --data-urlencode "CLUSTER_NAME=${cluster_name}" \
        --data-urlencode "DEPLOY_MTV=true" \
        --data-urlencode "GIT_BRANCH=main" \
        --data-urlencode "IIB_NO=${iib}" \
        --data-urlencode "MATRIX_TYPE=RELEASE" \
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
        --data-urlencode "RUN_TESTS_IN_PARALLEL=true" \
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
    local cluster_name="${5:-qemtv-01}"  # Default to qemtv-01 if not provided
    
    # Convert comma-separated OCP versions to array
    IFS=',' read -ra OCP_VERSIONS_ARRAY <<< "$ocp_versions"
    
    # Trigger jobs for each OCP version
    for openshift_version in "${OCP_VERSIONS_ARRAY[@]}"; do
        # Trim whitespace
        openshift_version=$(echo "$openshift_version" | xargs)
        
        if ! trigger_jenkins_job "$openshift_version" "$iib" "$mtv_version" "$rc" "$cluster_name"; then
            log_error "Failed to trigger job for OCP version: $openshift_version"
            return 1
        fi
    done
    
    log_success "All jobs triggered successfully. Waiting for completion..."
    echo
    return 0
}

# Function to export job tracking data for handoff to next stage
export_job_data() {
    local output_file="${1:-job_tracking.json}"
    
    echo "{" > "$output_file"
    echo "  \"jobs\": [" >> "$output_file"
    
    local first=true
    for job_name in "${!JOB_TRACKING[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$output_file"
        fi
        
        local job_info="${JOB_TRACKING[$job_name]}"
        local parsed_info=$(parse_job_info "$job_info")
        local job_number="${parsed_info%%|*}"
        local remaining="${parsed_info#*|}"
        local job_url="${remaining%%|*}"
        
        # Extract OCP version using shared function
        local ocp_version=$(extract_ocp_version_from_parsed_info "$remaining")
        
        echo "    {" >> "$output_file"
        echo "      \"job_name\": \"$job_name\"," >> "$output_file"
        echo "      \"job_number\": \"$job_number\"," >> "$output_file"
        echo "      \"job_url\": \"$job_url\"," >> "$output_file"
        echo "      \"ocp_version\": \"$ocp_version\"" >> "$output_file"
        echo -n "    }" >> "$output_file"
    done
    
    echo "" >> "$output_file"
    echo "  ]" >> "$output_file"
    echo "}" >> "$output_file"
    
    log_success "Job tracking data exported to: $output_file"
}


# Standalone execution support
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Script is being run directly, not sourced
    
    case "${1:-}" in
        "trigger")
            if [ $# -lt 5 ] || [ $# -gt 6 ]; then
                echo "Usage: $0 trigger <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME]"
                exit 1
            fi
            trigger_all_jobs "$2" "$3" "$4" "$5" "${6:-qemtv-01}"
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
            echo "  trigger <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME]  - Trigger jobs and export data"
            echo "  import <job_data_file>                                         - Import job data from file"
            echo "  export [output_file]                                           - Export current job data"
            echo
            echo "Examples:"
            echo "  $0 trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'"
            echo "  $0 trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-02'"
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
export JOB_TRACKING
export JENKINS_BASE_URL

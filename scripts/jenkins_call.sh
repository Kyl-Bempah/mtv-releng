#!/bin/bash

# Jenkins job trigger script for MTV testing
# Usage: ./jenkins_call.sh <iib> <mtv-version> <ocp-versions> <dev-preview>

set -euo pipefail

# Source utility functions
source "$(dirname "$0")/util.sh"

# Constants
readonly JENKINS_BASE_URL="https://jenkins-csb-mtv-qe-main.dno.corp.redhat.com"
readonly MAX_WAIT_TIME=10800  # 3 hours in seconds
readonly POLL_INTERVAL=300    # 5 minutes in seconds
readonly SCRIPT_NAME="$(basename "$0")"

# Job status constants
readonly STATUS_RUNNING="RUNNING"
readonly STATUS_QUEUED="QUEUED"
readonly STATUS_UNKNOWN="UNKNOWN"
readonly STATUS_SUCCESS="SUCCESS"
readonly STATUS_FAILURE="FAILURE"
readonly STATUS_ABORTED="ABORTED"

# Global variables
declare -A JOB_TRACKING  # Associative array: job_name -> "job_number|job_url|ocp_version|trigger_time"
declare -A TRIGGER_TIMESTAMPS  # Track when each job was triggered

# Helper function to parse job information
parse_job_info() {
    local job_info="$1"
    local job_number="${job_info%%|*}"
    local remaining="${job_info#*|}"
    
    # Handle both old format (job_number|job_url|ocp_version) and new format (job_number|job_url|ocp_version|trigger_time)
    # Split by | and handle the last two parts as ocp_version and optionally trigger_time
    local parts=($(echo "$remaining" | tr '|' '\n'))
    local num_parts=${#parts[@]}
    
    if [ $num_parts -eq 2 ]; then
        # Old format: job_url|ocp_version
        local job_url="${parts[0]}"
        local ocp_version="${parts[1]}"
        echo "$job_number|$job_url|$ocp_version"
    elif [ $num_parts -eq 3 ]; then
        # New format: job_url|ocp_version|trigger_time
        local job_url="${parts[0]}"
        local ocp_version="${parts[1]}"
        local trigger_time="${parts[2]}"
        echo "$job_number|$job_url|$ocp_version|$trigger_time"
    else
        # Fallback: try to extract URL and version from remaining string
        local job_url="${remaining%|*}"
        local last_part="${remaining##*|}"
        if [[ "$last_part" =~ ^[0-9]+\.[0-9]+$ ]]; then
            # Old format: job_number|job_url|ocp_version
            local ocp_version="$last_part"
            echo "$job_number|$job_url|$ocp_version"
        else
            # New format: job_number|job_url|ocp_version|trigger_time
            local ocp_version="${last_part%|*}"
            local trigger_time="${last_part##*|}"
            echo "$job_number|$job_url|$ocp_version|$trigger_time"
        fi
    fi
}

# Function to validate that a build belongs to our triggered job
validate_build_ownership() {
    local job_name="$1"
    local build_number="$2"
    local expected_trigger_time="$3"
    
    # Get build details from Jenkins
    local build_url="${JENKINS_BASE_URL}/job/${job_name}/${build_number}/api/json"
    local build_response
    if ! build_response=$(jenkins_api_call "$build_url" ""); then
        return 1
    fi
    
    # Extract build timestamp
    local build_timestamp
    build_timestamp=$(echo "$build_response" | jq -r '.timestamp // empty' 2>/dev/null)
    if [ -z "$build_timestamp" ] || [ "$build_timestamp" = "null" ]; then
        return 1
    fi
    
    # Convert timestamps to seconds for comparison
    local build_time_seconds=$((build_timestamp / 1000))
    local trigger_time_seconds=$((expected_trigger_time / 1000))
    
    # Allow a 5-minute window for build to start after trigger
    local time_diff=$((build_time_seconds - trigger_time_seconds))
    if [ $time_diff -ge 0 ] && [ $time_diff -le 300 ]; then
        return 0  # Build is within expected timeframe
    else
        log_warning "Build #$build_number timestamp ($build_time_seconds) doesn't match expected trigger time ($trigger_time_seconds), diff: ${time_diff}s"
        return 1
    fi
}

# Function to validate build parameters match our triggered job
validate_build_parameters() {
    local job_name="$1"
    local build_number="$2"
    local expected_iib="$3"
    local expected_mtv_version="$4"
    
    # Get build parameters from Jenkins
    local build_url="${JENKINS_BASE_URL}/job/${job_name}/${build_number}/api/json"
    local build_response
    if ! build_response=$(jenkins_api_call "$build_url" ""); then
        return 1
    fi
    
    # Extract parameters
    local build_iib
    build_iib=$(echo "$build_response" | jq -r '.actions[].parameters[]? | select(.name=="IIB_NO") | .value // empty' 2>/dev/null | head -1)
    local build_mtv_version
    build_mtv_version=$(echo "$build_response" | jq -r '.actions[].parameters[]? | select(.name=="MTV_VERSION") | .value // empty' 2>/dev/null | head -1)
    
    # Validate IIB matches
    if [ -n "$build_iib" ] && [ "$build_iib" = "$expected_iib" ]; then
        # Validate MTV version matches
        if [ -n "$build_mtv_version" ] && [ "$build_mtv_version" = "$expected_mtv_version" ]; then
            return 0  # Parameters match
        else
            log_warning "Build #$build_number MTV version ($build_mtv_version) doesn't match expected ($expected_mtv_version)"
            return 1
        fi
    else
        log_warning "Build #$build_number IIB ($build_iib) doesn't match expected ($expected_iib)"
        return 1
    fi
}

# Function to display usage
usage() {
    cat << EOF
Usage: $SCRIPT_NAME <iib> <mtv-version> <ocp-versions> <dev-preview>

Arguments:
  iib              Index Image Build
  mtv-version      MTV version (e.g., 2.9.3)
  ocp-versions     Comma-separated OCP versions (e.g., 4.20,4.19)
  dev-preview      true or false

Environment variables required:
  JENKINS_USER     Jenkins username
  JENKINS_TOKEN    Jenkins API token

Examples:
  $SCRIPT_NAME "forklift-fbc-prod-v420:on-pr-xxxxx" "2.9.3" "4.20,4.19" "false"
  $SCRIPT_NAME "forklift-fbc-prod-v420:sha-xxxxx" "2.9.3" "4.20" "true"
EOF
    exit 1
}

# Function to validate inputs
validate_inputs() {
    if [ $# -ne 4 ]; then
        log_error "Missing required parameters"
        usage
    fi

    local iib="$1"
    local mtv_version="$2"
    local ocp_versions="$3"
    local dev_preview="$4"

    # Validate dev-preview parameter
    if [[ "$dev_preview" != "true" && "$dev_preview" != "false" ]]; then
        log_error "dev-preview must be 'true' or 'false'"
        exit 1
    fi

    # Check required environment variables
    if [ -z "${JENKINS_USER:-}" ] || [ -z "${JENKINS_TOKEN:-}" ]; then
        log_error "JENKINS_USER and JENKINS_TOKEN environment variables are required"
        exit 1
    fi

    # Validate OCP versions format
    if [[ ! "$ocp_versions" =~ ^[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+)*$ ]]; then
        log_error "Invalid OCP versions format. Expected: 4.20,4.19"
        exit 1
    fi

    echo "$iib" "$mtv_version" "$ocp_versions" "$dev_preview"
}

# Function to make Jenkins API call
jenkins_api_call() {
    local url="$1"
    local data="$2"
    local method="${3:-GET}"  # Default to GET, allow POST to be specified
    local include_headers="${4:-false}"  # Whether to include headers in response
    
    if [ -n "$data" ] && [ "$method" = "POST" ]; then
        # For POST requests with data (job triggering)
        if [ "$include_headers" = "true" ]; then
            curl -s -S -f -i --insecure --connect-timeout 15 --max-time 60 -X POST \
                --user "$JENKINS_USER:$JENKINS_TOKEN" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                --data "$data" \
                "$url"
        else
            curl -s -S -f --insecure --connect-timeout 15 --max-time 60 -X POST \
                --user "$JENKINS_USER:$JENKINS_TOKEN" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                --data "$data" \
                "$url"
        fi
    else
        # For GET requests (status checks)
        curl -s -S -f --insecure --connect-timeout 15 --max-time 60 \
            --user "$JENKINS_USER:$JENKINS_TOKEN" \
            "$url"
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
        # No valid job or queue URL found
        return 1
    fi
}

# Function to trigger Jenkins job
trigger_jenkins_job() {
    local openshift_version="$1"
    local iib="$2"
    local mtv_version="$3"
    local rc="$4"
	
	# Variable creation for XY version (drop trailing .z)
	local mtv_xy_version
	mtv_xy_version=$(echo "$mtv_version" | awk -F. '{print $1"."$2}')
	local job_name="mtv-${mtv_xy_version}-ocp-${openshift_version}-test-release-gate"
    local job_url="${JENKINS_BASE_URL}/job/${job_name}/buildWithParameters"
    
    log_info "Triggering job for OCP version: $openshift_version"
    
    # Trigger the job using direct curl with --data-urlencode (most readable approach)
    local response
    if ! response=$(curl -s -S -f -i --insecure --connect-timeout 15 --max-time 60 -X POST \
        --user "$JENKINS_USER:$JENKINS_TOKEN" \
        --data-urlencode "BRANCH=master" \
        --data-urlencode "CLUSTER_NAME=qemtv-01" \
        --data-urlencode "DEPLOY_MTV=true" \
        --data-urlencode "GIT_BRANCH=main" \
        --data-urlencode "IIB_NO=$iib" \
        --data-urlencode "MATRIX_TYPE=RELEASE" \
        --data-urlencode "MTV_API_TEST_GIT_USER=RedHatQE" \
        --data-urlencode "MTV_SOURCE=KONFLUX" \
        --data-urlencode "MTV_VERSION=$mtv_version" \
        --data-urlencode "MTV_XY_VERSION=$mtv_xy_version" \
        --data-urlencode "NFS_SERVER_IP=f02-h06-000-r640.rdu2.scalelab.redhat.com" \
        --data-urlencode "NFS_SHARE_PATH=/home/nfsshare" \
        --data-urlencode "OCP_VERSION=$openshift_version" \
        --data-urlencode "OCP_XY_VERSION=$openshift_version" \
        --data-urlencode "OPENSHIFT_PYTHON_WRAPPER_GIT_BRANCH=main" \
        --data-urlencode "PYTEST_EXTRA_PARAMS=--tc=release_test:true --tc=target_ocp_version:$openshift_version" \
        --data-urlencode "RC=$rc" \
        --data-urlencode "REMOTE_CLUSTER_NAME=qemtv-01" \
        --data-urlencode "RUN_TESTS_IN_PARALLEL=true" \
        "$job_url"); then
        log_error "Failed to trigger Jenkins job for OCP version: $openshift_version"
        return 1
    fi
    
    # Extract job number
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
    
    # Construct appropriate URL based on job number type
    local job_url_full
    if [[ "$job_number" =~ ^(PENDING_|QUEUED_) ]]; then
        # For pending/queued jobs, use job URL without build number
        job_url_full="${JENKINS_BASE_URL}/job/${job_name}/"
    else
        # For actual build numbers, include the build number
        job_url_full="${JENKINS_BASE_URL}/job/${job_name}/${job_number}/"
    fi
    
    # Record trigger timestamp
    local trigger_timestamp=$(date +%s)000  # Convert to milliseconds
    TRIGGER_TIMESTAMPS["$job_name"]="$trigger_timestamp"
    
    # Store job information with trigger time
    JOB_TRACKING["$job_name"]="${job_number}|${job_url_full}|${openshift_version}|${trigger_timestamp}"
    
    log_success "Job triggered successfully. Job number: $job_number"
    return 0
}

# Function to check job status
check_job_status() {
    local job_name="$1"
    local job_number="$2"
    
    # Handle pending jobs (no build number assigned yet)
    if [[ "$job_number" =~ ^PENDING_ ]]; then
        # Try to get the latest build number for this job
        local job_info_url="${JENKINS_BASE_URL}/job/${job_name}/api/json"
        local job_info_response
        if job_info_response=$(jenkins_api_call "$job_info_url" ""); then
            local latest_build
            latest_build=$(echo "$job_info_response" | jq -r '.lastBuild.number // empty' 2>/dev/null)
            if [ -n "$latest_build" ] && [ "$latest_build" != "null" ]; then
                # Check if this is a new build (not the same as what we stored)
                local stored_job_info="${JOB_TRACKING[$job_name]}"
                local stored_job_number="${stored_job_info%%|*}"
                
                # If we have a new build number, validate it belongs to our job
                if [[ "$stored_job_number" =~ ^PENDING_ ]] || [[ "$latest_build" != "${stored_job_number#*_}" ]]; then
                    # Parse stored info to get trigger time
                    local parsed_stored=$(parse_job_info "$stored_job_info")
                    local stored_trigger_time="${parsed_stored##*|}"
                    
                    # Validate this build belongs to our triggered job
                    if validate_build_ownership "$job_name" "$latest_build" "$stored_trigger_time"; then
                        log_info "Job started with build number: $latest_build (validated ownership)" >&2
                        # Update the stored job number
                        local parsed_stored=$(parse_job_info "$stored_job_info")
                        local ocp_version="${parsed_stored##*|}"
                        JOB_TRACKING["$job_name"]="${latest_build}|${JENKINS_BASE_URL}/job/${job_name}/${latest_build}/|${ocp_version}"
                        job_number="$latest_build"
                    else
                        log_warning "Build #$latest_build doesn't belong to our triggered job, continuing to wait..." >&2
                        echo "$STATUS_QUEUED"
                        return
                    fi
                else
                    # Still waiting for a new build
                    echo "$STATUS_QUEUED"
                    return
                fi
            else
                echo "$STATUS_QUEUED"
                return
            fi
        else
            echo "$STATUS_UNKNOWN"
            return
        fi
    # Handle queued jobs
    elif [[ "$job_number" =~ ^QUEUED_ ]]; then
        # Check if this job has already been updated to a build number
        # This prevents checking queue status multiple times
        local current_job_info="${JOB_TRACKING[$job_name]}"
        local current_parsed=$(parse_job_info "$current_job_info")
        local current_job_number="${current_parsed%%|*}"
        
        # If the job number has been updated, use the new one
        if [[ ! "$current_job_number" =~ ^QUEUED_ ]]; then
            job_number="$current_job_number"
            # Continue to check actual build status below
        else
            # Still queued, check queue status
            local queue_item="${job_number#QUEUED_}"
            local queue_url="${JENKINS_BASE_URL}/queue/item/${queue_item}/api/json"
            
            local queue_response
            if ! queue_response=$(jenkins_api_call "$queue_url" ""); then
                # Queue item no longer exists (404) - job likely started, try to get latest build
                log_warning "Queue item no longer exists for job: $job_name, checking for started build" >&2
                local job_info_url="${JENKINS_BASE_URL}/job/${job_name}/api/json"
                local job_info_response
                if job_info_response=$(jenkins_api_call "$job_info_url" ""); then
                    local latest_build
                    latest_build=$(echo "$job_info_response" | jq -r '.lastBuild.number // empty' 2>/dev/null)
                    if [ -n "$latest_build" ] && [ "$latest_build" != "null" ]; then
                        # Validate and update job tracking
                        local job_info="${JOB_TRACKING[$job_name]}"
                        local parsed_info=$(parse_job_info "$job_info")
                        local stored_trigger_time="${parsed_info##*|}"
                        
                        if validate_build_ownership "$job_name" "$latest_build" "$stored_trigger_time"; then
                            log_info "Job started with build number: $latest_build (validated ownership)" >&2
                            local parsed_stored=$(parse_job_info "$job_info")
                            local ocp_version="${parsed_stored##*|}"
                            JOB_TRACKING["$job_name"]="${latest_build}|${JENKINS_BASE_URL}/job/${job_name}/${latest_build}/|${ocp_version}"
                            job_number="$latest_build"
                            # Continue to check actual build status below
                        else
                            echo "$STATUS_UNKNOWN"
                            return
                        fi
                    else
                        echo "$STATUS_UNKNOWN"
                        return
                    fi
                else
                    echo "$STATUS_UNKNOWN"
                    return
                fi
            else
                # Queue response is valid, check if job has been assigned a build number
                if [ -z "$queue_response" ]; then
                    echo "$STATUS_UNKNOWN"
                    return
                fi
                
                # Debug: log queue response for troubleshooting (only if DEBUG is set)
                if [ "${DEBUG:-false}" = "true" ]; then
                    log_info "Queue response for $job_name: $(echo "$queue_response" | jq -c . 2>/dev/null || echo "$queue_response")" >&2
                fi
                
                # Check if job has been assigned a build number
                local build_number
                build_number=$(echo "$queue_response" | jq -r '.executable.number // empty' 2>/dev/null)
                
                if [ -n "$build_number" ] && [ "$build_number" != "null" ]; then
                    # Validate this build belongs to our triggered job
                    local job_info="${JOB_TRACKING[$job_name]}"
                    local parsed_info=$(parse_job_info "$job_info")
                    local stored_trigger_time="${parsed_info##*|}"
                    
                    if validate_build_ownership "$job_name" "$build_number" "$stored_trigger_time"; then
                        log_info "Job started with build number: $build_number (validated ownership)" >&2
                        # Update the stored job number
                        local parsed_info=$(parse_job_info "$job_info")
                        local ocp_version="${parsed_info##*|}"
                        JOB_TRACKING["$job_name"]="${build_number}|${JENKINS_BASE_URL}/job/${job_name}/${build_number}/|${ocp_version}"
                        job_number="$build_number"
                    else
                        log_warning "Build #$build_number doesn't belong to our triggered job, continuing to wait..." >&2
                        echo "$STATUS_QUEUED"
                        return
                    fi
                else
                    # Check if job is still in queue or has an error
                    local why
                    why=$(echo "$queue_response" | jq -r '.why // empty' 2>/dev/null)
                    if [ -n "$why" ] && [ "$why" != "null" ]; then
                        log_info "Job still in queue: $why" >&2
                    fi
                    echo "$STATUS_QUEUED"
                    return
                fi
            fi
        fi
    fi
    
    # Check job status
    local status_url="${JENKINS_BASE_URL}/job/${job_name}/${job_number}/api/json"
    local status_response
    if ! status_response=$(jenkins_api_call "$status_url" ""); then
        log_warning "Failed to check job status for: $job_name #$job_number" >&2
        echo "$STATUS_UNKNOWN"
        return
    fi
    
    if [ -z "$status_response" ]; then
        echo "$STATUS_UNKNOWN"
        return
    fi
    
    local status
    # Check if the job is still building/running
    local building
    building=$(echo "$status_response" | jq -r '.building // false' 2>/dev/null || echo "false")
    
    if [ "$building" = "true" ]; then
        status="$STATUS_RUNNING"
    else
        # Job is not building, check the result
        status=$(echo "$status_response" | jq -r '.result // "UNKNOWN"' 2>/dev/null || echo "$STATUS_UNKNOWN")
    fi
    
    echo "$status"
}

# Function to wait for job completion
wait_for_jobs() {
    log_info "Waiting for jobs to complete..."
    
    local start_time=$(date +%s)
    
    while true; do
        local all_complete=true
        local running_jobs=0
        local completed_jobs=0
        
        for job_name in "${!JOB_TRACKING[@]}"; do
            local job_info="${JOB_TRACKING[$job_name]}"
            local parsed_info=$(parse_job_info "$job_info")
            local job_number="${parsed_info%%|*}"
            local status
            
            # Check if job number has been updated from QUEUED to build number
            if [[ "$job_number" =~ ^QUEUED_ ]]; then
                # Check if JOB_TRACKING has been updated with a build number
                local current_job_info="${JOB_TRACKING[$job_name]}"
                local current_parsed=$(parse_job_info "$current_job_info")
                local current_job_number="${current_parsed%%|*}"
                
                if [[ ! "$current_job_number" =~ ^QUEUED_ ]]; then
                    # Job has been updated to a build number, use that
                    job_number="$current_job_number"
                fi
            fi
            
            status=$(check_job_status "$job_name" "$job_number")
            
            if [[ "$status" == "$STATUS_RUNNING" || "$status" == "$STATUS_UNKNOWN" || "$status" == "$STATUS_QUEUED" ]]; then
                all_complete=false
                running_jobs=$((running_jobs + 1))
            else
                completed_jobs=$((completed_jobs + 1))
            fi
        done
        
        if [ "$all_complete" = true ]; then
            log_success "All jobs completed"
            break
        fi
        
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $MAX_WAIT_TIME ]; then
            log_warning "Timeout: Jobs did not complete within $MAX_WAIT_TIME seconds"
            break
        fi
        
        log_info "Jobs status: $completed_jobs completed, $running_jobs still running... waiting $((POLL_INTERVAL / 60)) minutes"
        sleep $POLL_INTERVAL
    done
}

# Function to escape JSON string
escape_json_string() {
    local str="$1"
    # Escape backslashes, quotes, and newlines
    echo "$str" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g'
}

# Function to generate JSON output
generate_json_output() {
    local mtv_version="$1"
    local dev_preview="$2"
    local rc="$3"
    local iib="$4"
    
    # Escape input strings
    local escaped_mtv_version=$(escape_json_string "$mtv_version")
    local escaped_iib=$(escape_json_string "$iib")
    
    local json="{\"mtv_version\":\"$escaped_mtv_version\",\"dev_preview\":$dev_preview,\"rc\":$rc,\"iib\":\"$escaped_iib\",\"results\":["
    
    local first=true
    for job_name in "${!JOB_TRACKING[@]}"; do
        local job_info="${JOB_TRACKING[$job_name]}"
        local parsed_info=$(parse_job_info "$job_info")
        local job_number="${parsed_info%%|*}"
        local remaining="${parsed_info#*|}"
        local job_url_only="${remaining%%|*}"
        
        # Extract OCP version correctly
        local ocp_version
        if [[ "$remaining" =~ \|[0-9]+\.[0-9]+\| ]]; then
            # Format: job_url|ocp_version|trigger_time - extract middle part
            ocp_version=$(echo "$remaining" | cut -d'|' -f2)
        else
            # Format: job_url|ocp_version
            ocp_version="${remaining##*|}"
        fi
        
        # Use cached status from validate_job_results to avoid extra API calls
        local final_status="${JOB_STATUS_CACHE[$job_name]}"
        
        # Escape strings for JSON
        local escaped_ocp_version=$(escape_json_string "$ocp_version")
        local escaped_status=$(escape_json_string "$final_status")
        local escaped_url=$(escape_json_string "$job_url_only")
        
        if [ "$first" = true ]; then
            first=false
        else
            json+=","
        fi
        
        json+="{\"ocp_version\":\"$escaped_ocp_version\",\"status\":\"$escaped_status\",\"url\":\"$escaped_url\"}"
    done
    
    json+="]}"
    echo "$json"
}

# Global associative array to cache job statuses
declare -A JOB_STATUS_CACHE

# Function to validate job results
validate_job_results() {
    local failed_jobs=0
    local success_jobs=0
    local unknown_jobs=0
    local failed_job_details=()
    local unknown_job_details=()
    
    for job_name in "${!JOB_TRACKING[@]}"; do
        local job_info="${JOB_TRACKING[$job_name]}"
        local parsed_info=$(parse_job_info "$job_info")
        local job_number="${parsed_info%%|*}"
        local remaining="${parsed_info#*|}"
        local job_url_only="${remaining%%|*}"
        
        # Extract OCP version correctly
        local ocp_version
        if [[ "$remaining" =~ \|[0-9]+\.[0-9]+\| ]]; then
            # Format: job_url|ocp_version|trigger_time - extract middle part
            ocp_version=$(echo "$remaining" | cut -d'|' -f2)
        else
            # Format: job_url|ocp_version
            ocp_version="${remaining##*|}"
        fi
        
        # Get final status - if job is QUEUED, check if it has been updated to a build number
        local final_status
        if [[ "$job_number" =~ ^QUEUED_ ]]; then
            # Check if JOB_TRACKING has been updated with a build number
            local current_job_info="${JOB_TRACKING[$job_name]}"
            local current_parsed=$(parse_job_info "$current_job_info")
            local current_job_number="${current_parsed%%|*}"
            
            if [[ ! "$current_job_number" =~ ^QUEUED_ ]]; then
                # Job has been updated to a build number, use that
                job_number="$current_job_number"
            fi
        fi
        
        final_status=$(check_job_status "$job_name" "$job_number")
        
        # Cache the status for later use
        JOB_STATUS_CACHE["$job_name"]="$final_status"
        
        case "$final_status" in
            "$STATUS_SUCCESS")
                success_jobs=$((success_jobs + 1))
                ;;
            "$STATUS_FAILURE"|"$STATUS_ABORTED")
                failed_jobs=$((failed_jobs + 1))
                failed_job_details+=("OCP $ocp_version: $final_status - $job_url_only")
                ;;
            *)
                unknown_jobs=$((unknown_jobs + 1))
                unknown_job_details+=("OCP $ocp_version: $final_status - $job_url_only")
                ;;
        esac
    done
    
    log_info "Job Results Summary: $success_jobs succeeded, $failed_jobs failed, $unknown_jobs unknown"
    
    # Display detailed error information
    if [ $failed_jobs -gt 0 ]; then
        echo
        log_error "FAILED JOBS:"
        echo "============="
        for job_detail in "${failed_job_details[@]}"; do
            echo -e "${RED}✗ $job_detail${NC}"
        done
        echo
    fi
    
    if [ $unknown_jobs -gt 0 ]; then
        echo
        log_warning "UNKNOWN STATUS JOBS:"
        echo "====================="
        for job_detail in "${unknown_job_details[@]}"; do
            echo -e "${YELLOW}? $job_detail${NC}"
        done
        echo
    fi
    
    # Return non-zero if any jobs failed or have unknown status
    if [ $failed_jobs -gt 0 ] || [ $unknown_jobs -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Function to display results
display_results() {
    log_info "Job Results:"
    echo "============"
    
    for job_name in "${!JOB_TRACKING[@]}"; do
        local job_info="${JOB_TRACKING[$job_name]}"
        local parsed_info=$(parse_job_info "$job_info")
        local job_number="${parsed_info%%|*}"
        local remaining="${parsed_info#*|}"
        local job_url_only="${remaining%%|*}"
        
        # Extract OCP version correctly
        local ocp_version
        if [[ "$remaining" =~ \|[0-9]+\.[0-9]+\| ]]; then
            # Format: job_url|ocp_version|trigger_time - extract middle part
            ocp_version=$(echo "$remaining" | cut -d'|' -f2)
        else
            # Format: job_url|ocp_version
            ocp_version="${remaining##*|}"
        fi
        
        # Use cached status from validate_job_results to avoid extra API calls
        local final_status="${JOB_STATUS_CACHE[$job_name]}"
        
        local status_color
        case "$final_status" in
            "$STATUS_SUCCESS") status_color="$GREEN" ;;
            "$STATUS_FAILURE"|"$STATUS_ABORTED") status_color="$RED" ;;
            *) status_color="$YELLOW" ;;
        esac
        
        echo -e "${ocp_version}: ${status_color}${final_status}${NC} - [URL](${job_url_only})"
    done
}

# Main function
main() {
    # Parse and validate inputs
    local inputs
    inputs=$(validate_inputs "$@")
    read -r IIB MTV_VERSION OCP_VERSIONS DEV_PREVIEW <<< "$inputs"
    
    # Set RC based on dev-preview
    local RC
    if [ "$DEV_PREVIEW" = "true" ]; then
        RC="false"
    else
        RC="true"
    fi
    
    # Display configuration
    log_info "Starting MTV test jobs..."
    log_info "IIB: $IIB"
    log_info "MTV Version: $MTV_VERSION"
    log_info "OCP Versions: $OCP_VERSIONS"
    log_info "Dev Preview: $DEV_PREVIEW"
    log_info "RC: $RC"
    echo
    
    # Convert comma-separated OCP versions to array
    IFS=',' read -ra OCP_VERSIONS_ARRAY <<< "$OCP_VERSIONS"
    
    # Trigger jobs for each OCP version
    for openshift_version in "${OCP_VERSIONS_ARRAY[@]}"; do
        # Trim whitespace
        openshift_version=$(echo "$openshift_version" | xargs)
        
        if ! trigger_jenkins_job "$openshift_version" "$IIB" "$MTV_VERSION" "$RC"; then
            log_error "Failed to trigger job for OCP version: $openshift_version"
            exit 1
        fi
    done
    
    log_success "All jobs triggered successfully. Waiting for completion..."
    echo
    
    # Wait for all jobs to complete
    wait_for_jobs
    
    # Validate job results first (populates cache)
    if ! validate_job_results; then
        echo
        log_error "OVERALL RESULT: FAILURE"
        log_error "One or more jobs failed or have unknown status"
        echo
        log_info "JSON Output:"
        echo "============"
        generate_json_output "$MTV_VERSION" "$DEV_PREVIEW" "$RC" "$IIB"
        echo
        log_error "Script exiting with error code 1"
        exit 1
    fi
    
    # Display results (uses cached status)
    display_results
    echo
    
    # Output JSON
    log_info "JSON Output:"
    echo "============"
    generate_json_output "$MTV_VERSION" "$DEV_PREVIEW" "$RC" "$IIB"
    
    log_success "All jobs completed successfully!"
    exit 0
}

# Run main function with all arguments
main "$@"
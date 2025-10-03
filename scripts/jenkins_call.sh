#!/bin/bash

# Jenkins job trigger script for MTV testing
# Usage: ./jenkins_call.sh <iib> <mtv-version> <ocp-versions> <dev-preview>

set -euo pipefail

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

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
declare -A JOB_TRACKING  # Associative array: job_name -> "job_number|job_url|ocp_version"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Function to display usage
usage() {
    cat << EOF
Usage: $SCRIPT_NAME <iib> <mtv-version> <ocp-versions> <dev-preview>

Arguments:
  iib              Index Image Bundle
  mtv-version      MTV version (e.g., 2.9.3)
  ocp-versions     Comma-separated OCP versions (e.g., 4.20,4.19)
  dev-preview      true or false

Environment variables required:
  JENKINS_USER     Jenkins username
  JENKINS_TOKEN    Jenkins API token

Examples:
  $SCRIPT_NAME "my-iib" "2.9.3" "4.20,4.19" "false"
  $SCRIPT_NAME "iib-123" "2.9.3" "4.20" "true"
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
    
    if [ -n "$data" ] && [ "$method" = "POST" ]; then
        # For POST requests with data (job triggering)
        curl -s -i --insecure -X POST \
            --user "$JENKINS_USER:$JENKINS_TOKEN" \
            --data-urlencode "$data" \
            "$url"
    else
        # For GET requests (status checks)
        curl -s --insecure \
            --user "$JENKINS_USER:$JENKINS_TOKEN" \
            "$url"
    fi
}

# Function to extract job number from Jenkins response
extract_job_number() {
    local response="$1"
    local location_header
    
    location_header=$(echo "$response" | grep -i '^Location:' | head -1)
    
    if [ -z "$location_header" ]; then
        return 1
    fi

    # Handle direct job URLs: /job/jobname/123/
    if echo "$location_header" | grep -q "/job/.*/[0-9]\+/"; then
        echo "$location_header" | grep -o '/job/[^/]*/[0-9]\+/' | grep -o '[0-9]\+' | head -1
    # Handle queue item URLs: /queue/item/123
    elif echo "$location_header" | grep -q "/queue/item/[0-9]\+"; then
        local queue_item
        queue_item=$(echo "$location_header" | grep -o '/queue/item/[0-9]\+' | grep -o '[0-9]\+')
        log_info "Job queued with queue item: $queue_item"
        echo "QUEUED_${queue_item}"
    else
        # Fallback: extract any number
        echo "$location_header" | grep -o '[0-9]\+' | head -1
    fi
}

# Function to trigger Jenkins job
trigger_jenkins_job() {
    local openshift_version="$1"
    local iib="$2"
    local mtv_version="$3"
    local rc="$4"
    
    local job_name="mtv-${mtv_version}-ocp-${openshift_version}-test-release-gate"
    local job_url="${JENKINS_BASE_URL}/job/${job_name}/build"
    
    log_info "Triggering job for OCP version: $openshift_version"
    
    # Build JSON parameters
    local json_params
    json_params=$(cat << EOF
{
  "parameter": [
    {"name": "OCP_VERSION", "value": "${openshift_version}"},
    {"name": "IIB_NO", "value": "${iib}"},
    {"name": "MTV_VERSION", "value": "${mtv_version}"},
    {"name": "RC", "value": "${rc}"},
    {"name": "CLUSTER_NAME", "value": "qemtv-01"},
    {"name": "DEPLOY_MTV", "value": "true"}
  ]
}
EOF
    )
    
    # Trigger the job
    local response
    response=$(jenkins_api_call "$job_url" "json=${json_params}" "POST")
    
    # Extract job number
    local job_number
    if ! job_number=$(extract_job_number "$response"); then
        log_error "Failed to extract job number from Jenkins response"
        return 1
    fi
    
    local job_url_full="${JENKINS_BASE_URL}/job/${job_name}/${job_number}/"
    
    # Store job information
    JOB_TRACKING["$job_name"]="${job_number}|${job_url_full}|${openshift_version}"
    
    log_success "Job triggered successfully. Job number: $job_number"
    return 0
}

# Function to check job status
check_job_status() {
    local job_name="$1"
    local job_number="$2"
    
    # Handle queued jobs
    if [[ "$job_number" =~ ^QUEUED_ ]]; then
        local queue_item="${job_number#QUEUED_}"
        local queue_url="${JENKINS_BASE_URL}/queue/item/${queue_item}/api/json"
        
        local queue_response
        queue_response=$(jenkins_api_call "$queue_url" "")
        
        if [ -z "$queue_response" ]; then
            echo "$STATUS_UNKNOWN"
            return
        fi
        
        # Check if job has been assigned a build number
        local build_number
        if command -v jq >/dev/null 2>&1; then
            build_number=$(echo "$queue_response" | jq -r '.executable.number // empty' 2>/dev/null)
        else
            build_number=$(echo "$queue_response" | grep -o '"number"[[:space:]]*:[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' | head -1)
        fi
        
        if [ -n "$build_number" ] && [ "$build_number" != "null" ]; then
            log_info "Job started with build number: $build_number"
            # Update the stored job number
            local job_info="${JOB_TRACKING[$job_name]}"
            local job_url="${job_info#*|}"
            local ocp_version="${job_url#*|}"
            JOB_TRACKING["$job_name"]="${build_number}|${JENKINS_BASE_URL}/job/${job_name}/${build_number}/|${ocp_version}"
            job_number="$build_number"
        else
            echo "$STATUS_QUEUED"
            return
        fi
    fi
    
    # Check job status
    local status_url="${JENKINS_BASE_URL}/job/${job_name}/${job_number}/api/json"
    local status_response
    status_response=$(jenkins_api_call "$status_url" "")
    
    if [ -z "$status_response" ]; then
        echo "$STATUS_UNKNOWN"
        return
    fi
    
    local status
    if command -v jq >/dev/null 2>&1; then
        status=$(echo "$status_response" | jq -r '.result // "RUNNING"' 2>/dev/null || echo "$STATUS_UNKNOWN")
    else
        # Fallback method using grep and sed
        status=$(echo "$status_response" | \
            grep -o '"result"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/"result"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' | \
            head -1)
        
        if [ -z "$status" ]; then
            status="$STATUS_RUNNING"
        fi
    fi
    
    echo "$status"
}

# Function to wait for job completion
wait_for_jobs() {
    log_info "Waiting for jobs to complete..."
    
    local all_complete=false
    local start_time=$(date +%s)
    
    while [ "$all_complete" = false ]; do
        all_complete=true
        
        for job_name in "${!JOB_TRACKING[@]}"; do
            local job_info="${JOB_TRACKING[$job_name]}"
            local job_number="${job_info%%|*}"
            local status
            
            status=$(check_job_status "$job_name" "$job_number")
            
            if [[ "$status" == "$STATUS_RUNNING" || "$status" == "$STATUS_UNKNOWN" || "$status" == "$STATUS_QUEUED" ]]; then
                all_complete=false
            fi
        done
        
        if [ "$all_complete" = false ]; then
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            
            if [ $elapsed -gt $MAX_WAIT_TIME ]; then
                log_warning "Timeout: Jobs did not complete within $MAX_WAIT_TIME seconds"
                break
            fi
            
            log_info "Jobs still running... waiting $((POLL_INTERVAL / 60)) minutes"
            sleep $POLL_INTERVAL
        fi
    done
}

# Function to generate JSON output
generate_json_output() {
    local mtv_version="$1"
    local dev_preview="$2"
    local rc="$3"
    local iib="$4"
    
    local json="{\"mtv_version\":\"$mtv_version\",\"dev_preview\":$dev_preview,\"rc\":$rc,\"iib\":\"$iib\",\"results\":["
    
    local first=true
    for job_name in "${!JOB_TRACKING[@]}"; do
        local job_info="${JOB_TRACKING[$job_name]}"
        local job_number="${job_info%%|*}"
        local job_url="${job_info#*|}"
        local ocp_version="${job_url#*|}"
        local job_url_only="${job_url%|*}"
        
        local final_status
        final_status=$(check_job_status "$job_name" "$job_number")
        
        if [ "$first" = true ]; then
            first=false
        else
            json+=","
        fi
        
        json+="{\"ocp_version\":\"$ocp_version\",\"status\":\"$final_status\",\"url\":\"$job_url_only\"}"
    done
    
    json+="]}"
    echo "$json"
}

# Function to display results
display_results() {
    log_info "Job Results:"
    echo "============"
    
    for job_name in "${!JOB_TRACKING[@]}"; do
        local job_info="${JOB_TRACKING[$job_name]}"
        local job_number="${job_info%%|*}"
        local job_url="${job_info#*|}"
        local ocp_version="${job_url#*|}"
        local job_url_only="${job_url%|*}"
        
        local final_status
        final_status=$(check_job_status "$job_name" "$job_number")
        
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
    
    # Display results
    display_results
    echo
    
    # Output JSON
    log_info "JSON Output:"
    echo "============"
    generate_json_output "$MTV_VERSION" "$DEV_PREVIEW" "$RC" "$IIB"
}

# Run main function with all arguments
main "$@"
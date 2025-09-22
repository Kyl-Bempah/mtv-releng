#!/bin/bash

# Jenkins job trigger script for MTV testing
# Usage: ./jenkins_call.sh <iib> <mtv-version> <ocp-versions> <dev-preview>

set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0 <iib> <mtv-version> <ocp-versions> <dev-preview>"
    echo "  iib: Index Image Bundle"
    echo "  mtv-version: MTV version (e.g., 2.9.3)"
    echo "  ocp-versions: Comma-separated OCP versions (e.g., 4.20,4.19)"
    echo "  dev-preview: true or false"
    echo ""
    echo "Environment variables required:"
    echo "  JENKINS_USER: Jenkins username"
    echo "  JENKINS_TOKEN: Jenkins API token"
    exit 1
}

# Check if required parameters are provided
if [ $# -ne 4 ]; then
    echo "Error: Missing required parameters"
    usage
fi

# Parse parameters
IIB="$1"
MTV_VERSION="$2"
OCP_VERSIONS="$3"
DEV_PREVIEW="$4"

# Validate dev-preview parameter
if [[ "$DEV_PREVIEW" != "true" && "$DEV_PREVIEW" != "false" ]]; then
    echo "Error: dev-preview must be 'true' or 'false'"
    exit 1
fi

# Check required environment variables
if [ -z "${JENKINS_USER:-}" ] || [ -z "${JENKINS_TOKEN:-}" ]; then
    echo "Error: JENKINS_USER and JENKINS_TOKEN environment variables are required"
    exit 1
fi

# Set RC based on dev-preview
if [ "$DEV_PREVIEW" = "true" ]; then
    RC="false"
else
    RC="true"
fi

echo "Starting MTV test jobs..."
echo "IIB: $IIB"
echo "MTV Version: $MTV_VERSION"
echo "OCP Versions: $OCP_VERSIONS"
echo "Dev Preview: $DEV_PREVIEW"
echo "RC: $RC"
echo ""

# Jenkins base URL
JENKINS_BASE_URL="https://jenkins-csb-mtv-qe-main.dno.corp.redhat.com"

# Arrays to store job information
declare -a JOB_NAMES
declare -a JOB_URLS
declare -a JOB_NUMBERS

# Function to trigger Jenkins job
trigger_jenkins_job() {
    local openshift_version="$1"
    local job_name="mtv-${MTV_VERSION}-ocp-${openshift_version}-test-release-gate"
    local job_url="${JENKINS_BASE_URL}/job/${job_name}/build"
    
    echo "Triggering job for OCP version: $openshift_version"
    
    # Generate timestamp for manifest
    local timestamp=$(date +%Y%m%d%H%M%S)
    
    # Trigger the job with all required parameters
    local response
    response=$(curl -s -i --insecure -X POST "$job_url" \
        --user "$JENKINS_USER:$JENKINS_TOKEN" \
        --data-urlencode "json={\"parameter\": [
            {\"name\":\"OCP_VERSION\", \"value\":\"${openshift_version}\"},
            {\"name\":\"IIB_NO\", \"value\":\"${IIB}\"},
            {\"name\":\"MTV_VERSION\", \"value\":\"${MTV_VERSION}\"},
            {\"name\":\"RC\", \"value\":\"${RC}\"},
            {\"name\":\"CLUSTER_NAME\", \"value\":\"qemtv-01\"},
            {\"name\":\"DEPLOY_MTV\", \"value\":\"true\"}
        ]}")
    
    # Extract job number from response
    local job_number
    local location_header
    
    # Get the Location header
    location_header=$(echo "$response" | grep -i '^Location:' | head -1)
    
    if [ -n "$location_header" ]; then
        # Extract job number from Location header
        # Handle both direct job URLs and queue item URLs
        if echo "$location_header" | grep -q "/job/.*/[0-9]\+/"; then
            # Direct job URL: /job/jobname/123/
            job_number=$(echo "$location_header" | grep -o '/job/[^/]*/[0-9]\+/' | grep -o '[0-9]\+' | head -1)
        elif echo "$location_header" | grep -q "/queue/item/[0-9]\+"; then
            # Queue item URL: /queue/item/123
            local queue_item
            queue_item=$(echo "$location_header" | grep -o '/queue/item/[0-9]\+' | grep -o '[0-9]\+')
            echo "Job queued with queue item: $queue_item"
            echo "Note: Job number will be determined when job starts"
            # For queue items, we'll need to poll the queue API to get the actual job number
            job_number="QUEUED_${queue_item}"
        else
            # Try to extract any number from the location
            job_number=$(echo "$location_header" | grep -o '[0-9]\+' | head -1)
        fi
    fi
    
    if [ -n "$job_number" ]; then
        echo "Job triggered successfully. Job number: $job_number"
        JOB_NAMES+=("$job_name")
        JOB_URLS+=("${JENKINS_BASE_URL}/job/${job_name}/${job_number}/")
        JOB_NUMBERS+=("$job_number")
    else
        echo "Error: Failed to trigger job for OCP version $openshift_version"
        return 1
    fi
}

# Function to check job status
check_job_status() {
    local job_name="$1"
    local job_number="$2"
    
    # Handle queued jobs
    if [[ "$job_number" =~ ^QUEUED_ ]]; then
        local queue_item="${job_number#QUEUED_}"
        local queue_url="${JENKINS_BASE_URL}/queue/item/${queue_item}/api/json"
        
        # Check if job is still in queue
        local queue_response
        queue_response=$(curl -s --insecure --user "$JENKINS_USER:$JENKINS_TOKEN" "$queue_url" 2>/dev/null)
        
        if [ -n "$queue_response" ]; then
            # Check if job has been assigned a build number
            local build_number
            if command -v jq >/dev/null 2>&1; then
                build_number=$(echo "$queue_response" | jq -r '.executable.number // empty' 2>/dev/null)
            else
                build_number=$(echo "$queue_response" | grep -o '"number"[[:space:]]*:[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' | head -1)
            fi
            
            if [ -n "$build_number" ] && [ "$build_number" != "null" ]; then
                # Job has started, update the job number and check status
                echo "Job started with build number: $build_number"
                # Update the job number for future checks
                job_number="$build_number"
            else
                echo "QUEUED"
                return
            fi
        else
            echo "UNKNOWN"
            return
        fi
    fi
    
    # Check job status
    local status_url="${JENKINS_BASE_URL}/job/${job_name}/${job_number}/api/json"
    
    local status
    # Use jq if available, otherwise fall back to grep/sed parsing
    if command -v jq >/dev/null 2>&1; then
        status=$(curl -s --insecure --user "$JENKINS_USER:$JENKINS_TOKEN" "$status_url" | \
            jq -r '.result // "RUNNING"' 2>/dev/null || echo "UNKNOWN")
    else
        # Fallback method using grep and sed
        status=$(curl -s --insecure --user "$JENKINS_USER:$JENKINS_TOKEN" "$status_url" | \
            grep -o '"result"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/"result"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' | \
            head -1)
        
        # If no result found, job is still running
        if [ -z "$status" ]; then
            status="RUNNING"
        fi
    fi
    
    echo "$status"
}

# Function to wait for job completion
wait_for_jobs() {
    echo "Waiting for jobs to complete..."
    
    local all_complete=false
    local max_wait_time=10800  # 3 hour timeout
    local start_time=$(date +%s)
    
    while [ "$all_complete" = false ]; do
        all_complete=true
        
        for i in "${!JOB_NAMES[@]}"; do
            local job_name="${JOB_NAMES[$i]}"
            local job_number="${JOB_NUMBERS[$i]}"
            local status
            
            status=$(check_job_status "$job_name" "$job_number")
            
            if [ "$status" = "RUNNING" ] || [ "$status" = "UNKNOWN" ] || [ "$status" = "QUEUED" ]; then
                all_complete=false
            fi
        done
        
        if [ "$all_complete" = false ]; then
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            
            if [ $elapsed -gt $max_wait_time ]; then
                echo "Timeout: Jobs did not complete within $max_wait_time seconds"
                break
            fi
            
            echo "Jobs still running... waiting 5 minutes"
            sleep 300
        fi
    done
}

# Main execution
# Convert comma-separated OCP versions to array
IFS=',' read -ra OCP_VERSIONS_ARRAY <<< "$OCP_VERSIONS"

# Trigger jobs for each OCP version
for openshift_version in "${OCP_VERSIONS_ARRAY[@]}"; do
    # Trim whitespace
    openshift_version=$(echo "$openshift_version" | xargs)
    
    if ! trigger_jenkins_job "$openshift_version"; then
        echo "Failed to trigger job for OCP version: $openshift_version"
        exit 1
    fi
done

echo ""
echo "All jobs triggered successfully. Waiting for completion..."

# Wait for all jobs to complete
wait_for_jobs

# Collect final results
echo ""
echo "Job Results:"
echo "============"

declare -a results
for i in "${!JOB_NAMES[@]}"; do
    local job_name="${JOB_NAMES[$i]}"
    local job_number="${JOB_NUMBERS[$i]}"
    local job_url="${JOB_URLS[$i]}"
    local openshift_version="${OCP_VERSIONS_ARRAY[$i]}"
    
    local final_status
    final_status=$(check_job_status "$job_name" "$job_number")
    
    local result_entry="${openshift_version}: ${final_status} - [URL](${job_url})"
    results+=("$result_entry")
    
    echo "$result_entry"
done

# Output results as JSON
echo ""
echo "JSON Output:"
echo "============"

# Create JSON output
json_output="{"
json_output+="\"mtv_version\":\"$MTV_VERSION\","
json_output+="\"dev_preview\":$DEV_PREVIEW,"
json_output+="\"rc\":$RC,"
json_output+="\"iib\":\"$IIB\","
json_output+="\"results\":["

for i in "${!results[@]}"; do
    if [ $i -gt 0 ]; then
        json_output+=","
    fi
    
    local openshift_version="${OCP_VERSIONS_ARRAY[$i]}"
    local job_url="${JOB_URLS[$i]}"
    local final_status
    final_status=$(check_job_status "${JOB_NAMES[$i]}" "${JOB_NUMBERS[$i]}")
    
    json_output+="{\"ocp_version\":\"$openshift_version\","
    json_output+="\"status\":\"$final_status\","
    json_output+="\"url\":\"$job_url\"}"
done

json_output+="]}"

echo "$json_output"
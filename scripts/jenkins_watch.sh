#!/usr/bin/env bash

# Jenkins job monitoring module
# Handles job status checking, waiting, and monitoring

set -euo pipefail

# Source utility functions
source "$(dirname "$0")/util.sh"

# Constants
readonly MAX_WAIT_TIME=10800  # 3 hours in seconds
readonly POLL_INTERVAL=300    # 5 minutes in seconds

# Global variables
declare -A JOB_TRACKING
declare -A JOB_STATUS_CACHE
declare -A QUEUE_PROCESSED

# Function to check job status
check_job_status() {
    local job_name="$1"
    local job_number="$2"
    
    # Handle PENDING jobs (no build number assigned yet)
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
                        log_info "Job started with build number: $latest_build" >&2
                        # Update the stored job number, preserving trigger timestamp
                        update_job_tracking_with_build "$job_name" "$latest_build"
                        job_number="$latest_build"
                        # Mark this queue item as processed
                        QUEUE_PROCESSED["$queue_cache_key"]="1"
                        # Continue to check actual build status below
                    else
                        log_warning "Build ownership validation failed for ${job_name}#${latest_build}, continuing to wait..." >&2
                        echo "$STATUS_QUEUED"
                        return
                    fi
                else
                    # Still pending
                    echo "$STATUS_QUEUED"
                    return
                fi
            else
                # Still pending
                echo "$STATUS_QUEUED"
                return
            fi
        else
            log_error "Failed to get job info for: $job_name" >&2
            echo "$STATUS_UNKNOWN"
            return
        fi
    fi
    
    # Handle QUEUED jobs
    if [[ "$job_number" =~ ^QUEUED_ ]]; then
        # Check if we've already processed this queue item
        local queue_item="${job_number#QUEUED_}"
        local queue_cache_key="${job_name}_${queue_item}"
        if [ -n "${QUEUE_PROCESSED[$queue_cache_key]:-}" ]; then
            echo "$STATUS_QUEUED"
            return
        fi
        
        # Get trigger timestamp from job tracking for validation
        local job_info="${JOB_TRACKING[$job_name]}"
        local parsed_info=$(parse_job_info "$job_info")
        local stored_trigger_time="${parsed_info##*|}"
        
        # Use shared function to check if queue item has resolved (single check mode)
        local executable_build
        if executable_build=$(resolve_queue_item_to_build "$job_name" "$queue_item" "$stored_trigger_time" 300 0 2>/dev/null); then
            # Job has started - update job tracking
            log_info "Job started with build number: $executable_build" >&2
            # Update the stored job number, preserving trigger timestamp
            update_job_tracking_with_build "$job_name" "$executable_build"
            job_number="$executable_build"
            # Mark this queue item as processed
            QUEUE_PROCESSED["$queue_cache_key"]="1"
            # Continue to check actual build status below
        else
            # Job still waiting in queue or validation failed
            echo "$STATUS_QUEUED"
            return
        fi
    fi
    
    # Handle PENDING jobs (build number exists but job hasn't started)
    if [[ "$job_number" =~ ^PENDING_ ]]; then
        local build_number="${job_number#PENDING_}"
        local job_info="${JOB_TRACKING[$job_name]}"
        local parsed_info=$(parse_job_info "$job_info")
        local stored_trigger_time="${parsed_info##*|}"
        
        # Check if this build belongs to our triggered job
        if validate_build_ownership "$job_name" "$build_number" "$stored_trigger_time"; then
            log_info "Job started with build number: $build_number" >&2
            # Update the stored job number, preserving trigger timestamp
            update_job_tracking_with_build "$job_name" "$build_number"
            job_number="$build_number"
            # Continue to check actual build status below
        else
            log_warning "Build ownership validation failed for ${job_name}#${build_number}, continuing to wait..." >&2
            echo "$STATUS_QUEUED"
            return
        fi
    fi
    
    # Check actual build status
    local status_url="${JENKINS_BASE_URL}/job/${job_name}/${job_number}/api/json"
    local status_response
    
    if ! status_response=$(jenkins_api_call "$status_url" ""); then
        log_warning "Failed to get status for ${job_name}#${job_number}" >&2
        echo "$STATUS_UNKNOWN"
        return
    fi
    
    local build_status
    build_status=$(echo "$status_response" | jq -r '.result // empty' 2>/dev/null)
    
    if [ -z "$build_status" ] || [ "$build_status" = "null" ]; then
        echo "$STATUS_RUNNING"
    else
        echo "$build_status"
    fi
}

# Function to wait for all jobs to complete
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
            log_error "Maximum wait time exceeded ($MAX_WAIT_TIME seconds)"
            return 1
        fi
        
        log_info "Jobs status: $completed_jobs completed, $running_jobs still running... waiting $((POLL_INTERVAL / 60)) minutes"
        sleep $POLL_INTERVAL
    done
    
    return 0
}

# Function to validate job results and populate cache
validate_job_results() {
    local success_jobs=0
    local failed_jobs=0
    local running_jobs=0
    local queued_jobs=0
    local unknown_jobs=0
    
    for job_name in "${!JOB_TRACKING[@]}"; do
        local job_info="${JOB_TRACKING[$job_name]}"
        local parsed_info=$(parse_job_info "$job_info")
        local job_number="${parsed_info%%|*}"
        local final_status
        
        # Get final status - if job is QUEUED, check if it has been updated to a build number
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
                ;;
            "$STATUS_RUNNING")
                running_jobs=$((running_jobs + 1))
                ;;
            "$STATUS_QUEUED")
                queued_jobs=$((queued_jobs + 1))
                ;;
            *)
                unknown_jobs=$((unknown_jobs + 1))
                ;;
        esac
    done
    
    # Build summary message with all status counts
    local summary_parts=()
    [ $success_jobs -gt 0 ] && summary_parts+=("$success_jobs succeeded")
    [ $failed_jobs -gt 0 ] && summary_parts+=("$failed_jobs failed")
    [ $running_jobs -gt 0 ] && summary_parts+=("$running_jobs running")
    [ $queued_jobs -gt 0 ] && summary_parts+=("$queued_jobs queued")
    [ $unknown_jobs -gt 0 ] && summary_parts+=("$unknown_jobs unknown")
    
    local summary_msg="Job Results Summary:"
    if [ ${#summary_parts[@]} -gt 0 ]; then
        local IFS=', '
        summary_msg+=" ${summary_parts[*]}"
    else
        summary_msg+=" no jobs found"
    fi
    log_info "$summary_msg"
    
    # Return failure only for failed or unknown jobs (not for running/queued)
    if [ $failed_jobs -gt 0 ] || [ $unknown_jobs -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Function to export job status data for handoff to next stage
export_status_data() {
    local output_file="${1:-job_status.json}"
    
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
        
        local final_status="${JOB_STATUS_CACHE[$job_name]}"
        
        echo "    {" >> "$output_file"
        echo "      \"job_name\": \"$job_name\"," >> "$output_file"
        echo "      \"job_number\": \"$job_number\"," >> "$output_file"
        echo "      \"job_url\": \"$job_url\"," >> "$output_file"
        echo "      \"ocp_version\": \"$ocp_version\"," >> "$output_file"
        echo "      \"status\": \"$final_status\"" >> "$output_file"
        echo -n "    }" >> "$output_file"
    done
    
    echo "" >> "$output_file"
    echo "  ]" >> "$output_file"
    echo "}" >> "$output_file"
    
    log_success "Job status data exported to: $output_file"
}


# Standalone execution support
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Script is being run directly, not sourced
    
    case "${1:-}" in
        "watch")
            if [ $# -ne 2 ]; then
                echo "Usage: $0 watch <job_data_file>"
                exit 1
            fi
            import_job_data "$2"
            wait_for_jobs
            validate_job_results
            export_status_data "job_status.json"
            ;;
        "status")
            if [ $# -ne 2 ]; then
                echo "Usage: $0 status <job_data_file>"
                exit 1
            fi
            import_job_data "$2"
            validate_job_results
            export_status_data "job_status.json"
            ;;
        "import")
            if [ $# -ne 2 ]; then
                echo "Usage: $0 import <job_data_file>"
                exit 1
            fi
            import_job_data "$2"
            ;;
        "export")
            export_status_data "${2:-job_status.json}"
            ;;
        *)
            echo "Usage: $0 {watch|status|import|export} [args...]"
            echo
            echo "Commands:"
            echo "  watch <job_data_file>     - Import jobs, wait for completion, validate, export status"
            echo "  status <job_data_file>    - Import jobs, validate current status, export status"
            echo "  import <job_data_file>    - Import job data from file"
            echo "  export [output_file]      - Export current job status data"
            echo
            echo "Examples:"
            echo "  $0 watch job_tracking.json"
            echo "  $0 status job_tracking.json"
            echo "  $0 import job_tracking.json"
            echo "  $0 export my_status.json"
            exit 1
            ;;
    esac
fi

# Export functions and variables for use by other modules
export -f check_job_status
export -f wait_for_jobs
export -f validate_job_results
export -f export_status_data
export JOB_TRACKING
export JOB_STATUS_CACHE
export JENKINS_BASE_URL

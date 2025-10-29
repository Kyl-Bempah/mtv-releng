#!/bin/bash

# Jenkins job reporting module
# Handles result display, JSON output, and final reporting

set -euo pipefail

# Source utility functions
source "$(dirname "$0")/util.sh"

# Global variables
declare -A JOB_TRACKING
declare -A JOB_STATUS_CACHE

# Function to display job results
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
        
        echo -e "${status_color}${ocp_version}: ${final_status} - [URL](${job_url_only})${NC}"
    done
    echo
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

# Function to display failed jobs summary
display_failed_jobs() {
    local failed_jobs=()
    
    for job_name in "${!JOB_TRACKING[@]}"; do
        local final_status="${JOB_STATUS_CACHE[$job_name]}"
        if [[ "$final_status" == "$STATUS_FAILURE" || "$final_status" == "$STATUS_ABORTED" ]]; then
            local job_info="${JOB_TRACKING[$job_name]}"
            local parsed_info=$(parse_job_info "$job_info")
            local remaining="${parsed_info#*|}"
            local job_url_only="${remaining%%|*}"
            
            # Extract OCP version correctly
            local ocp_version
            if [[ "$remaining" =~ \|[0-9]+\.[0-9]+\| ]]; then
                ocp_version=$(echo "$remaining" | cut -d'|' -f2)
            else
                ocp_version="${remaining##*|}"
            fi
            
            failed_jobs+=("OCP ${ocp_version}: ${final_status} - ${job_url_only}")
        fi
    done
    
    if [ ${#failed_jobs[@]} -gt 0 ]; then
        log_error "FAILED JOBS:"
        echo "============="
        for failed_job in "${failed_jobs[@]}"; do
            echo "✗ ${failed_job}"
        done
        echo
    fi
}

# Function to import job status data from previous stage
import_status_data() {
    local input_file="$1"
    
    if [ ! -f "$input_file" ]; then
        log_error "Input file not found: $input_file"
        return 1
    fi
    
    # Clear existing data
    JOB_TRACKING=()
    JOB_STATUS_CACHE=()
    
    # Parse JSON and populate both arrays
    local job_count=$(jq '.jobs | length' "$input_file" 2>/dev/null)
    
    if [ -z "$job_count" ] || [ "$job_count" = "null" ]; then
        log_error "Invalid JSON format in: $input_file"
        return 1
    fi
    
    for ((i=0; i<job_count; i++)); do
        local job_name=$(jq -r ".jobs[$i].job_name" "$input_file" 2>/dev/null)
        local job_number=$(jq -r ".jobs[$i].job_number" "$input_file" 2>/dev/null)
        local job_url=$(jq -r ".jobs[$i].job_url" "$input_file" 2>/dev/null)
        local ocp_version=$(jq -r ".jobs[$i].ocp_version" "$input_file" 2>/dev/null)
        local status=$(jq -r ".jobs[$i].status" "$input_file" 2>/dev/null)
        
        if [ "$job_name" != "null" ] && [ "$job_number" != "null" ] && [ "$job_url" != "null" ] && [ "$ocp_version" != "null" ] && [ "$status" != "null" ]; then
            JOB_TRACKING["$job_name"]="${job_number}|${job_url}|${ocp_version}"
            JOB_STATUS_CACHE["$job_name"]="$status"
            log_info "Imported job: $job_name (build $job_number, status $status)"
        fi
    done
    
    log_success "Imported $job_count jobs with status from: $input_file"
    return 0
}

# Function to generate comprehensive report
generate_comprehensive_report() {
    local mtv_version="$1"
    local dev_preview="$2"
    local rc="$3"
    local iib="$4"
    local output_format="${5:-both}"  # 'display', 'json', or 'both'
    
    case "$output_format" in
        "display")
            display_results
            ;;
        "json")
            generate_json_output "$mtv_version" "$dev_preview" "$rc" "$iib"
            ;;
        "both"|*)
            display_results
            echo
            log_info "JSON Output:"
            echo "============"
            generate_json_output "$mtv_version" "$dev_preview" "$rc" "$iib"
            ;;
    esac
}

# Standalone execution support
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Script is being run directly, not sourced
    
    case "${1:-}" in
        "report")
            if [ $# -lt 5 ]; then
                echo "Usage: $0 report <status_data_file> <MTV_VERSION> <DEV_PREVIEW> <RC> <IIB> [format]"
                echo "  format: 'display', 'json', or 'both' (default: both)"
                exit 1
            fi
            import_status_data "$2"
            generate_comprehensive_report "$3" "$4" "$5" "$6" "${7:-both}"
            ;;
        "display")
            if [ $# -ne 2 ]; then
                echo "Usage: $0 display <status_data_file>"
                exit 1
            fi
            import_status_data "$2"
            display_results
            ;;
        "json")
            if [ $# -lt 6 ]; then
                echo "Usage: $0 json <status_data_file> <MTV_VERSION> <DEV_PREVIEW> <RC> <IIB>"
                exit 1
            fi
            import_status_data "$2"
            generate_json_output "$3" "$4" "$5" "$6"
            ;;
        "import")
            if [ $# -ne 2 ]; then
                echo "Usage: $0 import <status_data_file>"
                exit 1
            fi
            import_status_data "$2"
            ;;
        *)
            echo "Usage: $0 {report|display|json|import} [args...]"
            echo
            echo "Commands:"
            echo "  report <status_file> <MTV_VERSION> <DEV_PREVIEW> <RC> <IIB> [format]"
            echo "    - Generate comprehensive report (display + JSON)"
            echo "    - format: 'display', 'json', or 'both' (default: both)"
            echo "  display <status_file>"
            echo "    - Display results in human-readable format"
            echo "  json <status_file> <MTV_VERSION> <DEV_PREVIEW> <RC> <IIB>"
            echo "    - Generate JSON output only"
            echo "  import <status_file>"
            echo "    - Import job status data from file"
            echo
            echo "Examples:"
            echo "  $0 report job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123'"
            echo "  $0 display job_status.json"
            echo "  $0 json job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123'"
            echo "  $0 import job_status.json"
            exit 1
            ;;
    esac
fi

# Export functions and variables for use by other modules
export -f display_results
export -f generate_json_output
export -f display_failed_jobs
export -f import_status_data
export -f generate_comprehensive_report
export JOB_TRACKING
export JOB_STATUS_CACHE

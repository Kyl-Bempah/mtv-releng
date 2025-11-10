#!/usr/bin/env bash

# Jenkins job orchestrator script
# Coordinates triggering, watching, and reporting modules

# Source utility functions
source "$(dirname "$0")/util.sh"

# Source the three modules
source "$(dirname "$0")/jenkins_trigger.sh"
source "$(dirname "$0")/jenkins_watch.sh"
source "$(dirname "$0")/jenkins_report.sh"

# Constants
readonly SCRIPT_NAME="$(basename "$0")"

# Function to validate inputs
validate_inputs() {
    if [ -z "$JENKINS_USER" ] || [ -z "$JENKINS_TOKEN" ]; then
        log_error "JENKINS_USER and JENKINS_TOKEN environment variables must be set"
        exit 1
    fi

    if [ $# -lt 4 ] || [ $# -gt 5 ]; then
        log_error "Usage: $SCRIPT_NAME <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME]"
        log_error "  IIB: Image Index Bundle (e.g., 'forklift-fbc-prod-v420:on-pr-abc123')"
        log_error "  MTV_VERSION: MTV version (e.g., '2.10.0')"
        log_error "  OCP_VERSIONS: Comma-separated OCP versions (e.g., '4.20,4.21')"
        log_error "  RC: Release candidate flag ('true' or 'false')"
        log_error "  CLUSTER_NAME: Jenkins cluster name (default: 'qemtv-01')"
        exit 1
    fi
}

# Function to display usage
usage() {
    echo "Usage: $SCRIPT_NAME <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME]"
    echo
    echo "Arguments:"
    echo "  IIB          Image Index Bundle (e.g., 'forklift-fbc-prod-v420:on-pr-abc123')"
    echo "  MTV_VERSION  MTV version (e.g., '2.10.0')"
    echo "  OCP_VERSIONS Comma-separated OCP versions (e.g., '4.20,4.21')"
    echo "  RC           Release candidate flag ('true' or 'false')"
    echo "  CLUSTER_NAME Jenkins cluster name (default: 'qemtv-01')"
    echo
    echo "Environment Variables:"
    echo "  JENKINS_USER    Jenkins username"
    echo "  JENKINS_TOKEN   Jenkins API token"
    echo
    echo "Examples:"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-02'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20,4.21' 'true'"
}

# Main function
main() {
    # Validate inputs
    validate_inputs "$@"
    
    # Parse arguments
    local IIB="$1"
    local MTV_VERSION="$2"
    local OCP_VERSIONS="$3"
    local RC="$4"
    local CLUSTER_NAME="${5:-qemtv-01}"  # Default to qemtv-01 if not provided
    
    # Determine dev preview flag
    local DEV_PREVIEW="false"
    if [[ "$IIB" =~ dev-preview ]]; then
        DEV_PREVIEW="true"
    fi
    
    # Display startup information
    log_info "Starting MTV test jobs..."
    log_info "IIB: $IIB"
    log_info "MTV Version: $MTV_VERSION"
    log_info "OCP Versions: $OCP_VERSIONS"
    log_info "Dev Preview: $DEV_PREVIEW"
    log_info "RC: $RC"
    log_info "Cluster Name: $CLUSTER_NAME"
    echo
    
    # Step 1: Trigger all jobs
    if ! trigger_all_jobs "$IIB" "$MTV_VERSION" "$OCP_VERSIONS" "$RC" "$CLUSTER_NAME"; then
        log_error "Failed to trigger jobs"
        exit 1
    fi
    
    # Step 2: Wait for all jobs to complete
    if ! wait_for_jobs; then
        log_error "Failed to wait for jobs"
            exit 1
        fi
    
    # Step 3: Validate job results first (populates cache)
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
    
    # Step 4: Display results (uses cached status)
    display_results
    echo
    
    # Step 5: Output JSON
    log_info "JSON Output:"
    echo "============"
    generate_json_output "$MTV_VERSION" "$DEV_PREVIEW" "$RC" "$IIB"
    
    log_success "All jobs completed successfully!"
    exit 0
}

# Run main function with all arguments
main "$@"
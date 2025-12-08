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

    if [ $# -lt 4 ] || [ $# -gt 7 ]; then
        log_error "Usage: $SCRIPT_NAME <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME] [JOB_SUFFIX] [MATRIX_TYPE]"
        log_error "  IIB: Image Index Bundle (e.g., 'forklift-fbc-prod-v420:on-pr-abc123')"
        log_error "  MTV_VERSION: MTV version (e.g., '2.10.0')"
        log_error "  OCP_VERSIONS: Comma-separated OCP versions (e.g., '4.20,4.21')"
        log_error "  RC: Release candidate flag ('true' or 'false')"
        log_error "  CLUSTER_NAME: Jenkins cluster name (default: 'qemtv-01')"
        log_error "               - Single value: applies to all job suffixes (e.g., 'qemtv-01', 'qemtv-02')"
        log_error "               - Mapping format: different clusters per suffix (e.g., 'gate:qemtv-01,non-gate:qemtv-02')"
        log_error "  JOB_SUFFIX: Job name suffix (default: 'gate', can be comma-separated, e.g., 'gate', 'non-gate', 'gate,non-gate')"
        log_error "  MATRIX_TYPE: Matrix type (default: 'RELEASE')"
        log_error "               - Single value: applies to all job suffixes (e.g., 'RELEASE', 'FULL', 'STAGE', 'TIER1')"
        log_error "               - Mapping format: different matrix types per suffix (e.g., 'gate:RELEASE,non-gate:FULL')"
        exit 1
    fi
}

# Function to display usage
usage() {
    echo "Usage: $SCRIPT_NAME <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME] [JOB_SUFFIX] [MATRIX_TYPE]"
    echo
    echo "Arguments:"
    echo "  IIB          Image Index Bundle (e.g., 'forklift-fbc-prod-v420:on-pr-abc123')"
    echo "  MTV_VERSION  MTV version (e.g., '2.10.0')"
    echo "  OCP_VERSIONS Comma-separated OCP versions (e.g., '4.20,4.21')"
    echo "  RC           Release candidate flag ('true' or 'false')"
    echo "  CLUSTER_NAME Jenkins cluster name (default: 'qemtv-01')"
    echo "               - Single value: applies to all job suffixes (e.g., 'qemtv-01', 'qemtv-02')"
    echo "               - Mapping format: different clusters per suffix (e.g., 'gate:qemtv-01,non-gate:qemtv-02')"
    echo "  JOB_SUFFIX   Job name suffix (default: 'gate', can be comma-separated, e.g., 'gate', 'non-gate', 'gate,non-gate')"
    echo "  MATRIX_TYPE  Matrix type (default: 'RELEASE')"
    echo "               - Single value: applies to all job suffixes (e.g., 'RELEASE', 'FULL', 'STAGE', 'TIER1')"
    echo "               - Mapping format: different matrix types per suffix (e.g., 'gate:RELEASE,non-gate:FULL')"
    echo
    echo "Environment Variables:"
    echo "  JENKINS_USER    Jenkins username"
    echo "  JENKINS_TOKEN   Jenkins API token"
    echo
    echo "Examples:"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-02'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20,4.21' 'true'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-01' 'non-gate' 'FULL'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-01' 'gate,non-gate' 'RELEASE'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-01' 'gate,non-gate' 'gate:RELEASE,non-gate:FULL'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'gate:qemtv-01,non-gate:qemtv-02' 'gate,non-gate' 'RELEASE'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'gate:qemtv-01,non-gate:qemtv-02' 'gate,non-gate' 'gate:RELEASE,non-gate:FULL'"
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
    local JOB_SUFFIX="${6:-gate}"  # Default to "gate" for backward compatibility
    local MATRIX_TYPE="${7:-RELEASE}"  # Default to "RELEASE" for backward compatibility
    
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
    log_info "Job Suffix: $JOB_SUFFIX"
    log_info "Matrix Type: $MATRIX_TYPE"
    echo
    
    # Step 1: Trigger all jobs
    if ! trigger_all_jobs "$IIB" "$MTV_VERSION" "$OCP_VERSIONS" "$RC" "$CLUSTER_NAME" "$JOB_SUFFIX" "$MATRIX_TYPE"; then
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
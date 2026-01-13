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

    if [ $# -lt 4 ] || [ $# -gt 8 ]; then
        log_error "Usage: $SCRIPT_NAME <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME] [JOB_SUFFIX] [MATRIX_TYPE] [IIB_MAP]"
        log_error "  IIB: Image Index Bundle (e.g., 'forklift-fbc-prod-v420:on-pr-abc123')"
        log_error "  MTV_VERSION: MTV version (e.g., '2.10.0')"
        log_error "  OCP_VERSIONS: Comma-separated OCP versions (e.g., '4.20,4.21')"
        log_error "  RC: Release candidate flag ('true' or 'false')"
        log_error "  CLUSTER_NAME: Jenkins cluster name (default: 'qemtv-01')"
        log_error "               - Single value: applies to all (e.g., 'qemtv-01')"
        log_error "               - Suffix mapping: per job suffix (e.g., 'gate:qemtv-01,non-gate:qemtv-02')"
        log_error "               - OCP mapping: per OCP version (e.g., '4.19:qemtv-01,4.20:qemtv-02')"
        log_error "               - Combined mapping: per OCP and suffix (e.g., '4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03')"
        log_error "               - Config file: use '@path/to/config.json' to load from JSON file"
        log_error "  JOB_SUFFIX: Job name suffix (default: 'gate', can be comma-separated, e.g., 'gate', 'non-gate', 'gate,non-gate')"
        log_error "  MATRIX_TYPE: Matrix type (default: 'RELEASE')"
        log_error "               - Single value: applies to all job suffixes (e.g., 'RELEASE', 'FULL', 'STAGE', 'TIER1')"
        log_error "               - Mapping format: different matrix types per suffix (e.g., 'gate:RELEASE,non-gate:FULL')"
        log_error "  IIB_MAP: IIB mapping (optional, if not provided, uses single IIB value for all jobs)"
        log_error "          - Single value: applies to all (same as IIB argument)"
        log_error "          - Suffix mapping: per job suffix (e.g., 'gate:forklift-fbc-prod-v420:on-pr-abc123,non-gate:forklift-fbc-prod-v420:on-pr-xyz789')"
        log_error "          - OCP mapping: per OCP version (e.g., '4.19:forklift-fbc-prod-v420:on-pr-abc123,4.20:forklift-fbc-prod-v420:on-pr-xyz789')"
        log_error "          - Combined mapping: per OCP and suffix (e.g., '4.19:gate:forklift-fbc-prod-v420:on-pr-abc123,4.19:non-gate:forklift-fbc-prod-v420:on-pr-xyz789')"
        exit 1
    fi
}

# Function to display usage
usage() {
    echo "Usage: $SCRIPT_NAME <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME] [JOB_SUFFIX] [MATRIX_TYPE] [IIB_MAP]"
    echo
    echo "Arguments:"
    echo "  IIB          Image Index Bundle (e.g., 'forklift-fbc-prod-v420:on-pr-abc123')"
    echo "  MTV_VERSION  MTV version (e.g., '2.10.0')"
    echo "  OCP_VERSIONS Comma-separated OCP versions (e.g., '4.20,4.21')"
    echo "  RC           Release candidate flag ('true' or 'false')"
    echo "  CLUSTER_NAME Jenkins cluster name (default: 'qemtv-01')"
    echo "               - Single value: applies to all (e.g., 'qemtv-01')"
    echo "               - Suffix mapping: per job suffix (e.g., 'gate:qemtv-01,non-gate:qemtv-02')"
    echo "               - OCP mapping: per OCP version (e.g., '4.19:qemtv-01,4.20:qemtv-02')"
    echo "               - Combined mapping: per OCP and suffix (e.g., '4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03')"
    echo "               - Config file: use '@path/to/config.json' to load from JSON file"
    echo "  JOB_SUFFIX   Job name suffix (default: 'gate', can be comma-separated, e.g., 'gate', 'non-gate', 'gate,non-gate')"
    echo "  MATRIX_TYPE  Matrix type (default: 'RELEASE')"
    echo "               - Single value: applies to all job suffixes (e.g., 'RELEASE', 'FULL', 'STAGE', 'TIER1')"
    echo "               - Mapping format: different matrix types per suffix (e.g., 'gate:RELEASE,non-gate:FULL')"
    echo "  IIB_MAP      IIB mapping (optional, if not provided, uses single IIB value for all jobs)"
    echo "               - Single value: applies to all (same as IIB argument)"
    echo "               - Suffix mapping: per job suffix (e.g., 'gate:forklift-fbc-prod-v420:on-pr-abc123,non-gate:forklift-fbc-prod-v420:on-pr-xyz789')"
    echo "               - OCP mapping: per OCP version (e.g., '4.19:forklift-fbc-prod-v420:on-pr-abc123,4.20:forklift-fbc-prod-v420:on-pr-xyz789')"
    echo "               - Combined mapping: per OCP and suffix (e.g., '4.19:gate:forklift-fbc-prod-v420:on-pr-abc123,4.19:non-gate:forklift-fbc-prod-v420:on-pr-xyz789')"
    echo
    echo "Environment Variables:"
    echo "  JENKINS_USER        Jenkins username (required)"
    echo "  JENKINS_TOKEN       Jenkins API token (required)"
    echo "  JENKINS_CONFIG_FILE Path to JSON config file (optional, auto-used if CLUSTER_NAME not provided)"
    echo "  JENKINS_CLUSTER_MAP Cluster mapping (optional, can override CLUSTER_NAME arg)"
    echo "  JENKINS_JOB_SUFFIX  Job suffix (optional, can override JOB_SUFFIX arg)"
    echo "  JENKINS_MATRIX_MAP  Matrix type mapping (optional, can override MATRIX_TYPE arg)"
    echo "  JENKINS_IIB_MAP     IIB mapping (optional, can override IIB_MAP arg)"
    echo
    echo "Examples:"
    echo "  # Basic usage"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'"
    echo ""
    echo "  # Using JSON config file (cleanest for complex configurations)"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.19,4.20' 'false' '@jenkins_config.json'"
    echo ""
    echo "  # Using environment variables"
    echo "  export JENKINS_CLUSTER_MAP='4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03,4.20:non-gate:qemtv-04'"
    echo "  export JENKINS_MATRIX_MAP='gate:RELEASE,non-gate:FULL'"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.19,4.20' 'false' '' 'gate,non-gate'"
    echo ""
    echo "  # Inline arguments (good for automation/scripts)"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.19,4.20' 'false' \\"
    echo "    '4.19:gate:qemtv-01,4.19:non-gate:qemtv-02,4.20:gate:qemtv-03,4.20:non-gate:qemtv-04' \\"
    echo "    'gate,non-gate' 'gate:RELEASE,non-gate:FULL'"
    echo ""
    echo "  # Different IIB values per job"
    echo "  $SCRIPT_NAME 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.19,4.20' 'false' 'qemtv-01' 'gate,non-gate' 'RELEASE' \\"
    echo "    'gate:forklift-fbc-prod-v420:on-pr-abc123,non-gate:forklift-fbc-prod-v420:on-pr-xyz789'"
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
    
    # Check if CLUSTER_NAME is a config file reference (starts with @)
    local CLUSTER_NAME="${5:-}"
    local JOB_SUFFIX="${6:-}"
    local MATRIX_TYPE="${7:-}"
    local IIB_MAP="${8:-}"
    
    # Check for environment variable pointing to config file
    if [ -z "$CLUSTER_NAME" ] && [ -n "${JENKINS_CONFIG_FILE:-}" ]; then
      CLUSTER_NAME="@${JENKINS_CONFIG_FILE}"
    fi
    
    # If CLUSTER_NAME starts with @, it's a config file reference
    if [[ "$CLUSTER_NAME" =~ ^@ ]]; then
      local config_file="${CLUSTER_NAME#@}"
      # Expand environment variables in path
      config_file=$(eval echo "$config_file")
      # Expand ~ and resolve relative paths
      config_file="${config_file/#\~/$HOME}"
      if [[ ! "$config_file" =~ ^/ ]]; then
        # Relative path - resolve from script directory
        config_file="$(dirname "$0")/$config_file"
      fi
      
      # Load configuration from file
      local config_data
      if ! config_data=$(load_config_from_file "$config_file"); then
        log_error "Failed to load configuration from: $config_file"
        exit 1
      fi
      
      # Parse config data: CLUSTER_MAP|MATRIX_MAP|JOB_SUFFIX|IIB_MAP
      IFS='|' read -r CLUSTER_NAME MATRIX_TYPE JOB_SUFFIX IIB_MAP_FROM_CONFIG <<< "$config_data"
      
      # Override with explicit arguments if provided
      JOB_SUFFIX="${6:-$JOB_SUFFIX}"
      MATRIX_TYPE="${7:-$MATRIX_TYPE}"
      IIB_MAP="${8:-${IIB_MAP_FROM_CONFIG:-}}"
    else
      # Use environment variables or defaults
      CLUSTER_NAME="${CLUSTER_NAME:-${JENKINS_CLUSTER_MAP:-qemtv-01}}"
      JOB_SUFFIX="${JOB_SUFFIX:-${JENKINS_JOB_SUFFIX:-gate}}"
      MATRIX_TYPE="${MATRIX_TYPE:-${JENKINS_MATRIX_MAP:-RELEASE}}"
    fi
    
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
    if ! trigger_all_jobs "$IIB" "$MTV_VERSION" "$OCP_VERSIONS" "$RC" "$CLUSTER_NAME" "$JOB_SUFFIX" "$MATRIX_TYPE" "$IIB_MAP"; then
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
#!/bin/bash

# singleton env var to prevent reexporting during multiple "source scripts/util.sh" calls
if [[ -z "${CMD_OUTPUT_PATH:-}" ]]; then
  export CMD_OUTPUT_PATH=$(pwd)
fi

if [[ -z "${MAIN_WORKER_PID:-}" ]]; then
  export MAIN_WORKER_PID=$$
fi

# Prevent multiple sourcing of readonly variables
if [[ -z "${UTIL_SOURCED:-}" ]]; then
  export UTIL_SOURCED=1
  
  # Constants
  readonly JENKINS_BASE_URL="https://jenkins-csb-mtv-qe-main.dno.corp.redhat.com"
  
  # Status constants
  readonly STATUS_SUCCESS="SUCCESS"
  readonly STATUS_FAILURE="FAILURE"
  readonly STATUS_RUNNING="RUNNING"
  readonly STATUS_QUEUED="QUEUED"
  readonly STATUS_ABORTED="ABORTED"
  readonly STATUS_UNKNOWN="UNKNOWN"
  
  # Colors for output
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly BLUE='\033[0;34m'
  readonly NC='\033[0m' # No Color
fi

# Function to parse job info from JOB_TRACKING
parse_job_info() {
    local job_info="$1"
    local job_number="${job_info%%|*}"
    local remaining="${job_info#*|}"
    
    local parts=($(echo "$remaining" | tr '|' '\n'))
    local num_parts=${#parts[@]}
    
    if [ $num_parts -eq 2 ]; then
        local job_url="${parts[0]}"
        local ocp_version="${parts[1]}"
        echo "$job_number|$job_url|$ocp_version"
    elif [ $num_parts -eq 3 ]; then
        local job_url="${parts[0]}"
        local ocp_version="${parts[1]}"
        local trigger_time="${parts[2]}"
        echo "$job_number|$job_url|$ocp_version|$trigger_time"
    else
        local job_url="${remaining%|*}"
        local last_part="${remaining##*|}"
        if [[ "$last_part" =~ ^[0-9]+\.[0-9]+$ ]]; then
            local ocp_version="$last_part"
            echo "$job_number|$job_url|$ocp_version"
        else
            local ocp_version="${last_part%|*}"
            local trigger_time="${last_part##*|}"
            echo "$job_number|$job_url|$ocp_version|$trigger_time"
        fi
    fi
}

# Function to make Jenkins API calls with proper authentication and error handling
jenkins_api_call() {
    local url="$1"
    local data="$2"
    local method="${3:-GET}"  # Default to GET, allow POST to be specified
    local include_headers="${4:-false}"  # Whether to include headers in response
    
    # Debug: Check if authentication is available
    if [ -z "${JENKINS_USER:-}" ] || [ -z "${JENKINS_TOKEN:-}" ]; then
        log_error "JENKINS_USER or JENKINS_TOKEN not set for API call to: $url" >&2
        return 1
    fi
    
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

# Function to escape strings for JSON output
escape_json_string() {
    local str="$1"
    # Escape backslashes, quotes, and newlines
    echo "$str" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g'
}

# log message with worker id
function log {
  if [[ -z $mtv_worker_id ]]; then
    export mtv_worker_id="main"
  fi
  # kill runaway child process if parent is dead
  if [[ -z $(ps -e | grep $MAIN_WORKER_PID) ]]; then
    echo "Parent process exited, killing child..."
    kill -s 2 $$
  fi

  # just pretty printing
  if [[ $mtv_worker_id == "main" ]]; then
    w="[w] $mtv_worker_id"
  else
    w="[w] $mtv_worker_id"
  fi

  if [[ -n $mtv_parent_worker_id ]]; then
    if [[ $mtv_parent_worker_id == "main" ]]; then
      p="[p] $mtv_parent_worker_id"
    else
      p="[p] $mtv_parent_worker_id"
    fi
    p+=" $(date +"%T.%3N")"
    echo -e "\n┏$w $p\n$@\n"
  else
    w+=" $(date +"%T.%3N")"
    echo -e "\n┏$w\n$@\n"
  fi
}

# Color-coded logging functions
function log_info {
  echo -e "${BLUE}[INFO]${NC} $*"
}

function log_success {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

function log_warning {
  echo -e "${YELLOW}[WARNING]${NC} $*"
}

function log_error {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

function w_output {
  echo $@ | jq | tee -a "$CMD_OUTPUT_PATH/cmd_output"
}

function r_output {
  cat "$CMD_OUTPUT_PATH/cmd_output"
}

function cl_output {
  log "Clearing output file..."
  truncate -s 0 "$CMD_OUTPUT_PATH/cmd_output"
}

# yaml to json helper func
function ytj {
  echo $@ | yq -p yaml -o json
}

# execute asynchronously, only if main process is running
function async {
  if [[ -z $(ps -e | grep $MAIN_WORKER_PID) ]]; then
    exit
  fi
  (
    export mtv_parent_worker_id=$mtv_worker_id
    export mtv_worker_id=$(uuidgen | cut -d '-' -f 1)
    $@
  ) &
}

# wait for processes to finish, is used in conjuction with async
function process_sync {
  while true; do
    if [[ -n $(jobs | grep Done) ]]; then
      break
    fi
    sleep 1
  done
}

# prepare the temporary working directory
function temp_dir {
  if [[ -n $(ls | grep "temp-$mtv_worker_id") ]]; then
    rm -rf temp-$mtv_worker_id
  fi
  mkdir temp-$mtv_worker_id
  cd temp-$mtv_worker_id
}

# remove the temp working directory
function rm_temp_dir {
  cd ..
  if [[ -n $(ls | grep "temp-$mtv_worker_id") ]]; then
    rm -rf temp-$mtv_worker_id
  fi
}

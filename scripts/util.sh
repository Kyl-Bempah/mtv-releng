#!/bin/bash

# singleton env var to prevent reexporting during multiple "source scripts/util.sh" calls
if [[ -z $(echo $CMD_OUTPUT_PATH) ]]; then
  export CMD_OUTPUT_PATH=$(pwd)
fi

if [[ -z $(echo $MAIN_WORKER_PID) ]]; then
  export MAIN_WORKER_PID=$$
fi

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

# Function to validate required tools
function validate_tools {
    local missing_tools=()
    
    for tool in oc jq yq gh git; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "ERROR: Missing required tools: ${missing_tools[*]}"
        log "Please install the missing tools and try again."
        exit 1
    fi
}

#!/usr/bin/env bash

snapshot=$1

# Print Usage if argument is missing
if [[ -z $1 ]]; then
    echo "Usage: ./snapshot_content.sh <snapshot name>, examples:"
    echo "./snapshot_content.sh forklift-operator-2-9-ffrxv"
    exit 0
fi

oc get -o=json snapshot $snapshot | jq -e '.spec.components | map({ name, containerImage}) | sort'
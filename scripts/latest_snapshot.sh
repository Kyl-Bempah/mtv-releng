#!/bin/bash

# Gets the latest successful snapshot for specified version of forklift, e.g. forklift-operator-2-9...

version=$1

# Print Usage if argument is missing
if [[ -z $1 ]]; then
    echo -e "Gets the latest successful snapshot for specified version of forklift, e.g. forklift-operator-2-9...\n"
    echo "Usage: ./latest_snapshot.sh <version>, examples:"
    echo "./latest_snapshot.sh 2-9"
    echo "./latest_snapshot.sh dev-preview"
    exit 0
fi


oc get snapshots --sort-by='{.metadata.creationTimestamp}' -o custom-columns=NAME:.metadata.name | grep $version | tail -n 1
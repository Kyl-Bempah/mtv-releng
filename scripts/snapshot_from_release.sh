#!/usr/bin/env bash

# Gets the snapshot from specified release, e.g. forklift-operator-dev-preview-czdbc-540628f-hn27f

release=$1

# Print Usage if argument is missing
if [[ -z $1 ]]; then
    echo -e "Gets the snapshot from specified release, e.g. forklift-operator-dev-preview-czdbc-540628f-hn27f\n"
    echo "Usage: ./snapshot_from_release.sh <release>, examples:"
    echo "./snapshot_from_release.sh forklift-operator-dev-preview-czdbc-540628f-hn27f"
    exit 0
fi

snapshot=$(oc get -o json release $release | jq '.spec.snapshot')
# Strip quotes
echo ${snapshot:1:-1}
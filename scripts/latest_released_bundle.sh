#!/bin/bash

# Gets the latest successful release for specified version of forklift, e.g. forklift-operator-2-9...

version=$1
target=$2

# Print Usage if argument is missing
if [[ -z $1 || -z $2 ]]; then
    echo -e "Gets the latest successful release of a bundle for specified version of forklift.\n"
    echo "Usage: ./latest_released_commits.sh <version> <target>, examples:"
    echo "./latest_released_commits.sh 2-9 stage"
    echo "./latest_released_commits.sh 2-9 prod"
    echo "./latest_released_commits.sh dev-preview prod"
    exit 0
fi

scripts/latest_released_shas.sh $version $target 9 | grep bundle | awk '{ print $2 }'
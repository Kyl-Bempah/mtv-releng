#!/usr/bin/env bash

# Gets the latest successful release for specified version of forklift, e.g. forklift-operator-2-9...

version=$1
target=$2
rhel=$3

# Print Usage if argument is missing
if [[ -z $1 || -z $2 ]]; then
    echo -e "Gets the latest successful release for specified version of forklift, e.g. forklift-operator-2-9 rhel9 images release...\nIf [rhel] is omitted get the latest release without looking at the rhel version...\n"
    echo "Usage: ./latest_release.sh <version> <target> [rhel], examples:"
    echo "./latest_release.sh 2-9 stage 8"
    echo "./latest_release.sh 2-9 prod"
    echo "./latest_release.sh dev-preview prod 9"
    exit 0
fi

if [[ -z $3 ]]; then
    oc get releases --sort-by={.metadata.creationTimestamp} | grep Succeeded | tac | grep $version | grep rp-$target | awk '{print $1}' | head -n 1
else
    oc get releases --sort-by={.metadata.creationTimestamp} | grep Succeeded | tac | grep $version | grep rp-$target | grep '\-rhel'$rhel | awk '{print $1}' | head -n 1
fi

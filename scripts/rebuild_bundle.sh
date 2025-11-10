#!/usr/bin/env bash

version=$1

# Print Usage if argument is missing
if [[ -z $1 ]]; then
    echo "Usage: "
    echo "./rebuild_all.sh 2-9"
    echo "./rebuild_all.sh dev-preview"
    exit 0
fi

oc annotate components/forklift-operator-bundle-$version build.appstudio.openshift.io/request=trigger-pac-build
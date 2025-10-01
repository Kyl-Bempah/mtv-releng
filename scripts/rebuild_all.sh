#!/bin/bash

version=$1

# Print Usage if argument is missing
if [[ -z $1 ]]; then
    echo "Usage: "
    echo "./rebuild_all.sh 2-9"
    echo "./rebuild_all.sh dev-preview"
    exit 0
fi

oc annotate components/forklift-api-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/forklift-cli-download-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/forklift-console-plugin-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/forklift-controller-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/forklift-must-gather-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/forklift-operator-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/openstack-populator-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/ova-provider-server-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/ovirt-populator-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/populator-controller-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/validation-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/virt-v2v-$version build.appstudio.openshift.io/request=trigger-pac-build
oc annotate components/vsphere-xcopy-volume-populator-$version build.appstudio.openshift.io/request=trigger-pac-build

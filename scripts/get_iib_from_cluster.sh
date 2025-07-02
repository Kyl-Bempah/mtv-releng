#!/bin/bash

# Gets IIB of installed MTV from testing cluster

cs=$(oc describe sub -n openshift-mtv mtv-operator | yq '.Spec.Source')
csn=$(oc describe sub -n openshift-mtv mtv-operator | yq e '.Spec.["Source Namespace"]')
iib=$(oc describe catalogsource -n $csn $cs | yq '.Spec.Image')

csv=$(oc describe sub -n openshift-mtv mtv-operator | yq e '.Spec.["Starting CSV"]')
op_len=${#csv}
len=$(($op_len-5))

echo $iib
echo ${csv:$len}

echo "### RESULT ###"
echo $(jq --null-input --arg iib $iib --arg version ${csv:$len} '{iib: $iib, version: $version}')
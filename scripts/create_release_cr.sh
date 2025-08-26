#!/bin/bash

version="2-8-7"
snapshot="forklift-operator-2-8-mpc7s"
issues="""MTV-3218"""

declare -a rhel=("8" "9")
xy=${version%-*}

function add_issue {
  echo """          - id: $1
            source: issues.redhat.com"""
}

for rhel in ${rhel[@]}; do
  cr="""apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: forklift-operator-release-$version-rhel-$rhel
  namespace: rh-mtv-1-tenant
spec:
  releasePlan: forklift-operator-rp-prod-$xy-rhel$rhel
  snapshot: $snapshot
  data:
    releaseNotes:
      type: RHBA
      issues:
        fixed:"""

  echo "$cr" > release-$version-rhel${rhel}.yaml

  for issue in ${issues[@]}; do
    echo "$(add_issue $issue)" >> release-$version-rhel${rhel}.yaml
  done
done

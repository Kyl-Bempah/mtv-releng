#!/bin/bash

# Applies IDMS for testing the MTV in a cluster before release

cat << EOF > devel-idms.yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: devel-testing
spec:
  imageDigestMirrors:
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-controller-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-controller-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-api-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-api-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-must-gather-rhel8
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-must-gather-rhel8
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-console-plugin-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-console-plugin-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-validation-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-validation-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-virt-v2v-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-virt-v2v-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-populator-controller-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-populator-controller-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-rhv-populator-rhel8
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-rhv-populator-rhel8
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-openstack-populator-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-openstack-populator-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-ova-provider-server-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-ova-provider-server-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-vsphere-xcopy-volume-populator-rhel9
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-vsphere-xcopy-volume-populator-rhel9
    - mirrors:
        - registry.stage.redhat.io/migration-toolkit-virtualization/mtv-rhel9-operator
      source: registry.redhat.io/migration-toolkit-virtualization/mtv-rhel9-operator
EOF

oc apply -f devel-idms.yaml
rm devel-idms.yaml

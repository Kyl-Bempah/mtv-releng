# MTV Releng tooling

Currently only fuctionality is to parse build commits from IIB.

## Getting commits
`python main.py -i quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v418:on-pr-76657e65fa4e6ff445965976200aed1ad7adbb7d -v 2.9.0`

The tooling then:
1. parses IIB
2. finds used bundle
3. parses found bundle
4. finds used components
5. parses found components
6. finds build commits in labels `revision` or as a backup `vcs-ref`

> **NOTE**: `vcs-ref` label is not under our control so there is no guarantee of correct behavior across different build systems.
> 
> For Konflux however, even these should be set to reflect git commit from which the components were built.

### TODO Features
- branching helper
- latest IIB grabber
- commits diff of 2 IIBs   
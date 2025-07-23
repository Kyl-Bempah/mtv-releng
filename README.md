# MTV Releng tooling

## Getting commits

### Prerequisites

- Go to <https://access.redhat.com/terms-based-registry/> and create an account to login to registry.redhat.io if you don't have one yet
- Login to registry.redhat.io with above token

### Run

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

## Branching helper

This script is intended to help and automate tasks related to branching of MTV operator.
It's "modular" so you can choose what steps you want to execute and what to skip.

> **NOTE:** Before running, please look at the script and change the needed values (your fork urls)

### What exactly it does?

- creates release-X.Y branches for forklift, UI plugin and must gather
- modifies neccessary files with correct values
- pushes the changes into user's fork of the repository
- creates neccessary files for konflux with correct values
- pushes the changes to konflux releng repo

### Prerequisites

- forks of the repositories you want to branch

### How to run

Run `scripts/branching.sh` and follow the instructions...

## TODO Features

- latest IIB grabber
- commits diff of 2 IIBs

#!/usr/bin/env bash

# Script to sync the btrfs filesystem

set -e

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/util.sh"
source "$SCRIPT_DIR/auth.sh"

# ============================================================================
# Configuration Variables (can be overridden externally)
# ============================================================================

GIT_BRANCH=$1

if [ -z "$GIT_BRANCH" ]; then
    log_error "Usage: $0 <git_branch>"
    log_error "Example: $0 main"
    exit 1
fi

forklift_repo="https://github.com/kubev2v/forklift.git"
forklift_internal_repo="https://gitlab.cee.redhat.com/mtv/forklift.git"

# ============================================================================
# GitLab Authentication Setup
# ============================================================================
# For private GitLab repositories, authentication is required.
# Options:
# 1. Set GITLAB_TOKEN environment variable (Personal Access Token)
# 2. Set GITLAB_USER and GITLAB_TOKEN environment variables
# 3. Use SSH URLs instead (requires SSH keys configured)
# ============================================================================

# Build authenticated URL if token is provided
if [ -n "${GITLAB_TOKEN:-}" ]; then
    if [ -n "${GITLAB_USER:-}" ]; then
        # Use username:token format
        forklift_internal_repo="https://${GITLAB_USER}:${GITLAB_TOKEN}@gitlab.cee.redhat.com/mtv/forklift.git"
    else
        # Use oauth2:token format (GitLab accepts oauth2 as username with token)
        forklift_internal_repo="https://oauth2:${GITLAB_TOKEN}@gitlab.cee.redhat.com/mtv/forklift.git"
    fi
    log_info "Using GitLab authentication token"
elif [ -z "${GITLAB_TOKEN:-}" ]; then
    log_warning "GITLAB_TOKEN not set. Git operations on private repository may fail."
    log_warning "Set GITLAB_TOKEN environment variable with your GitLab Personal Access Token."
    log_warning "Alternatively, set GITLAB_USER and GITLAB_TOKEN for username:token authentication."
fi

# ============================================================================
# Main Sync Process
# ============================================================================
git config --global user.email "mtv-automation@redhat.com"
git config --global user.name "MTV Bot - BTRFS Sync automation"

tmp_dir=$(mktemp -d)
log_info "Cloning repository to temporary directory: $tmp_dir"

git clone $forklift_repo $tmp_dir
cd $tmp_dir
git checkout $GIT_BRANCH

log_info "Adding internal GitLab remote"
git remote add internal $forklift_internal_repo

log_info "Disable SSL verification"
git config http.sslVerify "false"

log_info "Pulling from internal repository (branch: $GIT_BRANCH)"
git pull internal $GIT_BRANCH --rebase

log_info "Pulling from origin repository (branch: $GIT_BRANCH)"
git pull origin $GIT_BRANCH --rebase

log_info "Pushing to internal repository (branch: $GIT_BRANCH)"
git push -f internal $GIT_BRANCH

log_success "Sync completed successfully"
# Jenkins Scripts - Bespoke Execution Guide

This guide explains how to run the Jenkins scripts individually for debugging, partial runs, or custom workflows.

## Overview

The Jenkins scripts are now modular and support both:
- **Integrated execution**: Run all stages together via `jenkins_call.sh`
- **Bespoke execution**: Run individual stages with data handoff between stages

## Data Handoff Files

The scripts use JSON files to pass data between stages:

- **`job_tracking.json`**: Contains job information after triggering (job names, numbers, URLs, OCP versions)
- **`job_status.json`**: Contains job information + final status after monitoring

## Script Commands

### 1. jenkins_trigger.sh - Job Triggering

```bash
# Trigger jobs and export data
./scripts/jenkins_trigger.sh trigger <IIB> <MTV_VERSION> <OCP_VERSIONS> <RC> [CLUSTER_NAME]

# Import job data from file
./scripts/jenkins_trigger.sh import <job_data_file>

# Export current job data
./scripts/jenkins_trigger.sh export [output_file]
```

**Examples:**
```bash
# Trigger jobs for OCP 4.20 (default cluster: qemtv-01)
./scripts/jenkins_trigger.sh trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'

# Trigger jobs for OCP 4.20 on specific cluster
./scripts/jenkins_trigger.sh trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-02'

# Import jobs from previous run
./scripts/jenkins_trigger.sh import job_tracking.json

# Export current jobs to custom file
./scripts/jenkins_trigger.sh export my_jobs.json
```

### 2. jenkins_watch.sh - Job Monitoring

```bash
# Watch jobs until completion and export status
./scripts/jenkins_watch.sh watch <job_data_file>

# Check current status without waiting
./scripts/jenkins_watch.sh status <job_data_file>

# Import job data from file
./scripts/jenkins_watch.sh import <job_data_file>

# Export current status data
./scripts/jenkins_watch.sh export [output_file]
```

**Examples:**
```bash
# Wait for jobs to complete
./scripts/jenkins_watch.sh watch job_tracking.json

# Check current status only
./scripts/jenkins_watch.sh status job_tracking.json

# Import jobs and export status
./scripts/jenkins_watch.sh import job_tracking.json
./scripts/jenkins_watch.sh export current_status.json
```

### 3. jenkins_report.sh - Result Reporting

```bash
# Generate comprehensive report (display + JSON)
./scripts/jenkins_report.sh report <status_data_file> <MTV_VERSION> <DEV_PREVIEW> <RC> <IIB> [format]

# Display results only
./scripts/jenkins_report.sh display <status_data_file>

# Generate JSON only
./scripts/jenkins_report.sh json <status_data_file> <MTV_VERSION> <DEV_PREVIEW> <RC> <IIB>

# Import status data from file
./scripts/jenkins_report.sh import <status_data_file>
```

**Examples:**
```bash
# Full report with both display and JSON
./scripts/jenkins_report.sh report job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123'

# Display only
./scripts/jenkins_report.sh display job_status.json

# JSON only
./scripts/jenkins_report.sh json job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123'

# Different output formats
./scripts/jenkins_report.sh report job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123' 'display'
./scripts/jenkins_report.sh report job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123' 'json'
```

## Common Workflows

### 1. Full Pipeline (Traditional)
```bash
# Default cluster (qemtv-01)
./scripts/jenkins_call.sh 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'

# Specific cluster
./scripts/jenkins_call.sh 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-02'
```

### 2. Trigger Only
```bash
# Default cluster (qemtv-01)
./scripts/jenkins_trigger.sh trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'

# Specific cluster
./scripts/jenkins_trigger.sh trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false' 'qemtv-02'
# Creates: job_tracking.json
```

### 3. Watch Previously Triggered Jobs
```bash
./scripts/jenkins_watch.sh watch job_tracking.json
# Creates: job_status.json
```

### 4. Report on Completed Jobs
```bash
./scripts/jenkins_report.sh report job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123'
```

### 5. Debugging Workflow
```bash
# Step 1: Trigger jobs
./scripts/jenkins_trigger.sh trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'

# Step 2: Check what was triggered
cat job_tracking.json

# Step 3: Watch jobs
./scripts/jenkins_watch.sh watch job_tracking.json

# Step 4: Check final status
cat job_status.json

# Step 5: Generate report
./scripts/jenkins_report.sh report job_status.json '2.10.0' 'false' 'true' 'forklift-fbc-prod-v420:on-pr-abc123'
```

### 6. Re-run Failed Jobs
```bash
# If jobs failed, you can re-trigger just the failed ones
# First, check what failed
./scripts/jenkins_report.sh display job_status.json

# Then trigger new jobs for failed OCP versions
./scripts/jenkins_trigger.sh trigger 'forklift-fbc-prod-v420:on-pr-abc123' '2.10.0' '4.20' 'false'
```

### 7. Status Check Only (No Waiting)
```bash
# Check current status without waiting for completion
./scripts/jenkins_watch.sh status job_tracking.json
```

## Data File Formats

### job_tracking.json
```json
{
  "jobs": [
    {
      "job_name": "mtv-2.10-ocp-4.20-test-release-gate",
      "job_number": "65",
      "job_url": "https://jenkins-csb-mtv-qe-main.dno.corp.redhat.com/job/mtv-2.10-ocp-4.20-test-release-gate/65/",
      "ocp_version": "4.20"
    }
  ]
}
```

### job_status.json
```json
{
  "jobs": [
    {
      "job_name": "mtv-2.10-ocp-4.20-test-release-gate",
      "job_number": "65",
      "job_url": "https://jenkins-csb-mtv-qe-main.dno.corp.redhat.com/job/mtv-2.10-ocp-4.20-test-release-gate/65/",
      "ocp_version": "4.20",
      "status": "SUCCESS"
    }
  ]
}
```

## Benefits of Bespoke Execution

1. **Debugging**: Run individual stages to isolate issues
2. **Partial Runs**: Resume from any stage if previous stages completed
3. **Custom Workflows**: Mix and match stages as needed
4. **Data Inspection**: Examine intermediate data files
5. **Re-runs**: Re-run specific stages without starting over
6. **Integration**: Use individual scripts in CI/CD pipelines

## Environment Variables

All scripts require:
- `JENKINS_USER`: Jenkins username
- `JENKINS_TOKEN`: Jenkins API token

## Jenkins Job Parameters

The scripts send the following parameters to Jenkins jobs:

- `BRANCH`: Git branch (master)
- `CLUSTER_NAME`: Jenkins cluster name (default: qemtv-01)
- `DEPLOY_MTV`: Deploy MTV flag (true)
- `GIT_BRANCH`: Git branch (main)
- `IIB_NO`: Image Index Bundle
- `MATRIX_TYPE`: Matrix type (RELEASE)
- `MTV_API_TEST_GIT_USER`: MTV API test git user (RedHatQE)
- `MTV_SOURCE`: MTV source (KONFLUX)
- `MTV_VERSION`: MTV version
- `MTV_XY_VERSION`: MTV XY version (e.g., 2.10 from 2.10.0)
- `NFS_SERVER_IP`: NFS server IP
- `NFS_SHARE_PATH`: NFS share path
- `OCP_VERSION`: OCP version
- `OCP_XY_VERSION`: OCP XY version
- `OPENSHIFT_PYTHON_WRAPPER_GIT_BRANCH`: Python wrapper branch (main)
- `PYTEST_EXTRA_PARAMS`: Pytest extra parameters
- `RC`: Release candidate flag
- `REMOTE_CLUSTER_NAME`: Remote cluster name (same as CLUSTER_NAME)
- `RUN_TESTS_IN_PARALLEL`: Run tests in parallel (true)

## Error Handling

- Each script validates inputs and provides clear error messages
- Data files are validated for proper JSON format
- Scripts exit with appropriate error codes for automation

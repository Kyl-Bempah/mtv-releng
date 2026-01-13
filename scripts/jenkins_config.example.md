# Jenkins Configuration File Example

This is an example JSON configuration file for Jenkins job triggering.

## File Format

See `jenkins_config.example.json` for the JSON structure.

## Usage Examples

### 1. Using config file directly:
```bash
./jenkins_call.sh <IIB> <MTV_VERSION> '4.19,4.20' <RC> '@jenkins_config.json'
```

### 2. Using environment variable:
```bash
export JENKINS_CONFIG_FILE=jenkins_config.json
./jenkins_call.sh <IIB> <MTV_VERSION> '4.19,4.20' <RC>
```

### 3. Config file priority (most specific first):
- `by_ocp_and_suffix` (most specific)
- `by_ocp_version`
- `by_suffix`
- `default` (least specific)

## Configuration Structure

- **clusters**: Defines cluster mappings
  - `default`: Default cluster for all jobs
  - `by_ocp_version`: Different clusters per OCP version
  - `by_suffix`: Different clusters per job suffix
  - `by_ocp_and_suffix`: Different clusters per OCP version AND suffix (most specific)

- **matrix_types**: Defines test matrix type mappings
  - `default`: Default matrix type
  - `by_suffix`: Different matrix types per job suffix

- **job_suffixes**: Defines common job suffix combinations
  - `default`: Default job suffix(es)
  - `common`: Common combinations (e.g., ["gate", "non-gate"])



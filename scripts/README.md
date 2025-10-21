# Bundle Sync Script

This script updates Containerfile-downstream SHA references with latest snapshot data and creates PRs.

## Usage

```bash
./scripts/bundle_sync.sh <version> [target_branch] [dry_run]
```

### Examples
```bash
# Dry run to see what would change
./scripts/bundle_sync.sh 2-10 main true

# Actually create PR
./scripts/bundle_sync.sh 2-10 main false
```

## Component Mappings

Component mappings are defined in `component_mappings.conf`. This file maps component names from snapshots to ARG names in Containerfile-downstream files.

### Format
```
component-name=ARG_NAME
```

### Example
```
forklift-api=API_IMAGE
forklift-controller=CONTROLLER_IMAGE
```

### Adding New Components

To add a new component mapping, simply edit `component_mappings.conf`:

1. Add a new line: `new-component=NEW_COMPONENT_IMAGE`
2. Test with dry run: `./scripts/bundle_sync.sh 2-10 main true`
3. If working, run for real: `./scripts/bundle_sync.sh 2-10 main false`

## Environment Variables

- `TARGET_REPO`: Target repository for PR creation (default: `kubev2v/forklift`)
- `COMPONENT_MAPPINGS_FILE`: Path to component mappings file (default: `./scripts/component_mappings.conf`)

## How It Works

1. **Gets latest snapshot** for the specified version
2. **Extracts SHA references** from the snapshot
3. **Maps components** to ARG names using the configuration file
4. **Updates Containerfile-downstream** with new SHA references
5. **Creates PR** in the target repository (if not dry run)

## Version Changes

The script handles version changes gracefully:

- **New components**: Will be reported as "Missing/Unknown" - add to config file
- **Removed components**: Will be reported as "Orphaned ARGs" - can be ignored
- **ARG name changes**: Will be reported as "Missing/Unknown" - update config file

The script provides detailed reporting of what components were processed, updated, skipped, or missing.

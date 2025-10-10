# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Nerves library that enables **zero-downtime firmware updates** by combining A/B partition safety with BEAM hot code reloading. The key innovation: firmware is written to the inactive partition and boot config is updated (making the device safe to boot the new firmware), but the system attempts hot code reload instead of rebooting when only application code has changed.

## Core Architecture

The system is built around a multi-stage orchestrated update process:

### 1. **Orchestrator** (`lib/nerves_zero_downtime/orchestrator.ex`)
- Main entry point for firmware updates via `apply_update/2`
- Coordinates the entire update workflow
- Makes strategic decisions: hot reload vs full reboot
- Calls other modules in sequence and handles failures gracefully
- Key flow: extract metadata → pre-validation → prepare partition → determine strategy → execute update → post-validation

### 2. **MetadataAnalyzer** (`lib/nerves_zero_downtime/metadata_analyzer.ex`)
- Compares current vs new firmware metadata to determine compatibility
- Extracts metadata from `.fw` files (ZIP archives containing `meta.conf`)
- Returns `:hot_reload_ok` or `{:reboot_required, reasons}`
- Checks for changes in: kernel version, device tree, ERTS version, NIF libraries, boot config, core OTP apps

### 3. **PartitionManager** (`lib/nerves_zero_downtime/partition_manager.ex`)
- Writes firmware to inactive partition using `fwup` utility
- Updates boot configuration (U-Boot environment variables or MBR)
- **Critical**: Always completes partition update BEFORE hot reload decision
- This ensures device can boot new firmware on unexpected reboot/power loss
- Sets `nerves_fw_pending_hot_reload` flag in U-Boot env

### 4. **HotReload** (`lib/nerves_zero_downtime/hot_reload.ex`)
- Extracts BEAM files from `.fw` to `/data/hot_reload/<version>/`
- Manages code paths and module reloading
- Two reload strategies: `:simple_reload` (purge + load modules) and `:relup` (planned, not yet implemented)
- Creates symlinks: `/data/hot_reload/staged` → target version, `/data/hot_reload/current` → active version
- Handles rollback by restoring previous code paths and reloading old modules
- Last resort: reboots if rollback fails

### 5. **StateManager** (`lib/nerves_zero_downtime/state_manager.ex`)
- Persists update state to `/data/zero_downtime_state.etf` (Erlang Term Format)
- Tracks: current version, staged version, active partition, update history (last 10 updates)
- Uses Nerves.Runtime.KV to read current firmware version and partition info

### 6. **Validator** (`lib/nerves_zero_downtime/validator.ex`)
- Pre-update checks: disk space (≥100MB on `/data`), system health, memory
- Post-update validation: applications running, no crashes, smoke tests
- Runs post-validation with 30-second timeout
- If validation fails after hot reload, triggers rollback

### 7. **FirmwareStager** (`lib/nerves_zero_downtime/firmware_stager.ex`)
- Manages staged firmware for SSH upload scenarios
- Uses PartitionReader to extract metadata from inactive partition
- Determines if staged firmware can be hot-reloaded
- Applies hot reload from partition-extracted files

### 8. **PartitionReader** (`lib/nerves_zero_downtime/partition_reader.ex`)
- Mounts the inactive partition read-only
- Reads metadata from standard Nerves locations (`/srv/erlang/meta.conf`)
- Extracts hot reload bundle if present
- Handles cleanup (unmounting) after use
- Works automatically with no configuration required

## Common Development Commands

### Build and Test
```bash
# Fetch dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test

# Run specific test
mix test test/nerves_zero_downtime_test.exs

# Generate documentation
MIX_ENV=docs mix docs
```

### Code Quality
```bash
# Format code
mix format

# Check formatting
mix format --check-formatted

# Run Dialyzer (if configured)
mix dialyzer
```

## Key Implementation Details

### Firmware File Structure
- `.fw` files are ZIP archives containing:
  - `meta.conf` - Firmware metadata (key=value format)
  - `hot_reload.tar.gz` - Tarball with BEAM files in `lib/` directory structure
  - Other partition data processed by `fwup`

### Hot Reload Safety Criteria
Hot reload is ONLY safe when ALL of these are true:
1. No kernel version change
2. No device tree changes (DTB hash unchanged)
3. No ERTS version change
4. No NIF library changes (native code cannot be hot-reloaded)
5. No boot config changes
6. No core OTP app version changes (kernel, stdlib, sasl, compiler)
7. Sufficient disk space (≥100MB on `/data`)
8. System healthy (memory, CPU, error rates)
9. Firmware not explicitly marked `hot_reload_capable: false`

### Update Flow Decisions
The Orchestrator determines strategy in this order:
1. If `force_reboot: true` option → full reboot
2. If MetadataAnalyzer returns `{:reboot_required, _}` → full reboot
3. If insufficient disk space or system unhealthy → full reboot
4. If firmware marked not hot-reload-capable → full reboot
5. Otherwise → attempt hot reload (with fallback to reboot on failure)

### Safety Guarantees
- **Power loss during update**: Device boots into new partition (partition update completed before hot reload)
- **Hot reload failure**: Automatic rollback to previous code, or reboot to new partition
- **System crash after hot reload**: U-Boot validation mechanism reverts to old partition if firmware not validated

### Integration Points
- **SSH firmware upload**: Set `config :ssh_subsystem_fwup, success_callback: {NervesZeroDowntime, :handle_firmware_update, []}`
  - Note: `handle_firmware_update/0` takes NO arguments (the MFA tuple has empty args list)
  - When called, fwup has already written firmware to inactive partition
  - System automatically mounts partition and reads metadata - **no configuration required**
- **Application startup**: Call `Nerves.Runtime.validate_firmware()` after successful boot to mark firmware as good
- **Nerves.Runtime.KV**: Used to read firmware metadata from U-Boot environment and determine active/inactive partitions
- **UBootEnv**: Optional dependency for writing U-Boot environment variables
- **Partition mounting**: Requires `mount` command and squashfs/ext4 kernel support (standard on Nerves systems)

## Module Dependencies
```
NervesZeroDowntime (public API)
  ├─> Orchestrator (programmatic updates with .fw file)
  │    ├─> MetadataAnalyzer (extracts/compares metadata)
  │    ├─> Validator (pre/post checks)
  │    ├─> PartitionManager (fwup, writes firmware)
  │    ├─> HotReload (BEAM extraction, module loading)
  │    └─> StateManager (persists update history)
  │
  └─> FirmwareStager (SSH upload scenarios)
       ├─> PartitionReader (mounts/reads inactive partition)
       ├─> MetadataAnalyzer (compares metadata)
       ├─> HotReload (module loading from extracted files)
       └─> Validator (pre/post checks)
```

## Important Notes for Code Changes

1. **Always maintain partition safety**: PartitionManager must complete before any hot reload attempt
2. **Metadata analysis is critical**: Be conservative - default to reboot when uncertain
3. **Rollback must be reliable**: If rollback fails, system must reboot (last resort)
4. **State persistence**: StateManager writes to `/data/` which survives firmware updates
5. **Error handling**: Most functions return `{:ok, result}` or `{:error, reason}` - preserve this pattern
6. **Logging**: Use Logger extensively - this code runs on embedded devices where debugging is hard
7. **Nerves.Runtime dependencies**: This library depends on Nerves Runtime being present
8. **Testing on host**: Most code will fail on host machine (no `/dev/mmcblk0`, no fwup, no Nerves.Runtime)

## Two Update Paths

The library supports two different update mechanisms:

### 1. Programmatic Updates (Direct .fw file access)
- Use: `NervesZeroDowntime.apply_update("/path/to/firmware.fw")`
- Flow: Orchestrator → PartitionManager → MetadataAnalyzer → HotReload
- Has direct access to firmware file throughout the process
- Can extract metadata and BEAM files on-demand
- Full control over the update process

### 2. SSH Upload Updates (via ssh_subsystem_fwup)
- Use: `mix upload` + callback config
- Flow: fwup (external) → handle_firmware_update/0 → FirmwareStager → PartitionReader → HotReload
- Firmware streamed directly to fwup, no file saved
- After fwup completes, PartitionReader mounts the inactive partition
- Reads metadata and extracts hot reload bundle directly from partition
- **No special configuration required** - works automatically

## Testing

Test on actual Nerves hardware:
1. Mark firmware with `mix firmware.enable_reload`
2. Build with `mix firmware`
3. Upload with `mix upload <device_ip>`
4. Monitor logs via SSH: `RingLogger.tail`

## Future Development Areas

Based on TODOs in the code:
- **Optimize partition reading**: Cache partition metadata to avoid repeated mounts
- **Support alternative partition layouts**: Handle non-standard Nerves systems
- **Better hot reload bundle detection**: Auto-discover BEAM files if no explicit bundle
- Implement proper statvfs for disk space checking (currently simplified)
- Implement relup support for OTP release upgrades (`:release_handler`)
- Implement backup of current running code before hot reload
- Implement proper code path removal for staged versions
- Add configurable smoke tests for applications
- Add better system health monitoring (memory pressure, CPU load, error rates)
- Handle NIF version changes gracefully
- Support reading from compressed firmware images on partition

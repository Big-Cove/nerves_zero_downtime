# NervesZeroDowntime

**Zero-downtime firmware updates for Nerves devices**

This library enables firmware updates without rebooting for application-level changes, while maintaining the safety guarantees of A/B partition updates.

## Key Innovation

The core innovation is combining two proven technologies:

1. **A/B Partition Updates** (existing Nerves mechanism) - Safe, atomic firmware updates with automatic rollback
2. **BEAM Hot Code Reloading** - Zero-downtime code updates while processes continue running

The magic: We perform **all** standard partition update steps (write firmware, update boot config) but defer the reboot, instead hot-reloading the application code. This means:

- ✅ **Zero downtime** for application updates
- ✅ **Full safety** - device ready to boot new firmware on any unexpected reboot/power loss
- ✅ **Automatic rollback** - both at hot-reload level and partition level
- ✅ **Smart detection** - automatically determines when reboot is required

## When It Works

**Hot reload capable** (zero downtime):
- Application code changes
- Business logic updates
- Configuration changes
- Bug fixes in Elixir/Erlang code

**Requires reboot**:
- Kernel updates
- Device tree changes
- ERTS version changes
- NIF library updates
- Core OTP application changes (kernel, stdlib, sasl)

The library automatically detects which category your update falls into.

## Installation

Add `nerves_zero_downtime` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nerves_zero_downtime, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Add to your application

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your app's children...
      MyApp.Supervisor
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Validate firmware after successful startup
    Nerves.Runtime.validate_firmware()

    {:ok, pid}
  end
end
```

### 2. Configure SSH subsystem 

In your `config/target.exs`:

```elixir
config :ssh_subsystem_fwup,
  success_callback: {NervesZeroDowntime, :handle_firmware_update, []}
```

### 3. Build firmware with hot reload enabled

Use the provided mix tasks to control hot reload behavior:

```bash
# For application code changes - enable hot reload
mix firmware.enable_reload
mix firmware
mix firmware.upload IP

# For system changes - require reboot
mix firmware.require_reboot
mix firmware
mix firmware.upload IP
```

Or use combined commands:

```bash
# Hot reload build
mix firmware.enable_reload && mix firmware && mix firmware.upload IP

# Reboot build
mix firmware.require_reboot && mix firmware && mix firmware.upload IP
```

See [HOT_RELOAD_SETUP.md](HOT_RELOAD_SETUP.md) for more details and advanced usage.

**Important:** Only mark releases as hot-reload capable when you've changed:
- ✅ Application code (Elixir/Erlang)
- ✅ Configuration
- ✅ Pure Elixir/Erlang dependencies

Do NOT mark for hot reload if you changed:
- ❌ Kernel version
- ❌ ERTS/OTP version
- ❌ NIFs or native libraries

### 4. Deploy firmware

```bash
# Upload to device
mix firmware.upload 192.168.1.100
```

The update will:
1. Write new firmware to inactive partition (via fwup)
2. Update boot configuration
3. Check for HOT_RELOAD marker file
4. If marked: Hot reload application code (no downtime!)
5. If not marked: Reboot to new partition (safe default)

**Tip:** Add aliases to your `mix.exs`:
```elixir
defp aliases do
  [
    "firmware.hot": ["nerves_zero_downtime.mark_hot_reload", "firmware"],
    "firmware": ["compile", "firmware"]
  ]
end
```

Then use:
- `mix firmware.hot && mix firmware.upload IP` - Hot reload
- `mix firmware && mix firmware.upload IP` - Regular reboot

## Usage Examples

### Programmatic Updates

```elixir
# Apply firmware update (auto-detects hot reload vs reboot)
NervesZeroDowntime.apply_update("/path/to/firmware.fw")
#=> {:ok, :hot_reloaded} or {:ok, :rebooting}

# Force reboot even if hot reload capable
NervesZeroDowntime.apply_update("/path/to/firmware.fw", force_reboot: true)

# Dry run - analyze but don't execute
NervesZeroDowntime.apply_update("/path/to/firmware.fw", dry_run: true)
```

### Check Status

```elixir
NervesZeroDowntime.status()
#=> %{
  current_version: "1.0.0",
  partition_active: "a",
  last_update: 1699564800,
  pending_hot_reload: false,
  update_history: [
    %{from_version: "0.9.0", to_version: "1.0.0", result: :hot_reloaded, timestamp: 1699564800}
  ]
}
```

### Manual Control

```elixir
# Check if staged update can be hot-reloaded
if NervesZeroDowntime.hot_reload_available?() do
  IO.puts("Can hot reload")
end

# Manually trigger rollback
NervesZeroDowntime.rollback()

# Manually reboot to new partition
NervesZeroDowntime.reboot_to_new_partition()
```

## How It Works

### Update Process Flow

```
1. Upload firmware.fw to device
   ↓
2. Extract and analyze metadata
   ↓
3. Write firmware to inactive partition (via fwup)
   ↓
4. Update U-Boot environment / MBR boot flags
   ↓
5. Check if hot reload is safe
   ├─→ Kernel/ERTS/NIF changed? → REBOOT
   ├─→ Only app code changed? → HOT RELOAD
   └─→ System unhealthy? → REBOOT (safe default)
   ↓
6a. HOT RELOAD path:
    - Extract BEAM files to /data/hot_reload/<version>/
    - Add code paths from /data
    - Load new modules
    - Validate system health
    - If success: Mark firmware as validated
    - If failure: Rollback and/or reboot
   ↓
6b. REBOOT path:
    - Trigger system reboot
    - Boot from new partition
    - Application validates firmware

7. Device running new code
   Ready to boot new partition on any reboot
```

### Safety Guarantees

**Power Loss Scenario:**
- Partition update completed before hot reload
- On next boot: Device boots into new partition
- No data loss, firmware validated on boot

**Hot Reload Failure:**
- Automatic rollback to previous code
- Partition still configured for new firmware
- Can retry or manually reboot to new partition

**System Crash:**
- Device boots into new partition
- U-Boot checks validation status
- If not validated: Auto-revert to old partition

## Requirements

- Nerves system with A/B partition support
- Writable `/data` partition with minimum 100MB free space
- `fwup` utility available on device
- Elixir 1.13 or later

## Limitations

- Only works for application-level code changes
- Requires sufficient disk space on `/data` partition
- NIF changes require reboot (cannot hot-reload native code)
- Relup support is planned but not yet implemented
- Currently uses simple module reload (not full OTP release upgrades)

## License

Copyright 2024 The Nerves Project

Licensed under the Apache License, Version 2.0.

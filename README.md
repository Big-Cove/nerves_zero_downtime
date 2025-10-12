# NervesZeroDowntime

**Zero-downtime firmware updates for Nerves devices**

This library enables firmware updates without rebooting for application-level changes, while maintaining the safety guarantees of A/B partition updates.

**THIS IS A PROOF OF CONCEPT AND NOT COMPLETE**

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
mix upload IP

# For system changes - require reboot
mix firmware.require_reboot
mix firmware
mix upload IP
```

Or use combined commands:

```bash
# Hot reload build
mix firmware.enable_reload && mix firmware && mix upload IP

# Reboot build
mix firmware.require_reboot && mix firmware && mix upload IP
```


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
mix upload 192.168.1.100
```

The update will:
1. Write new firmware to inactive partition (via fwup)
2. Update boot configuration
3. Check for HOT_RELOAD marker file
4. If marked: Hot reload application code (no downtime!)
5. If not marked: Reboot to new partition (safe default)

**Tip:** Add aliases to your `mix.exs` for convenience:
```elixir
defp aliases do
  [
    "firmware.hot": ["firmware.enable_reload", "firmware"],
    "firmware.reboot": ["firmware.require_reboot", "firmware"]
  ]
end
```

Then use:
- `mix firmware.hot && mix upload IP` - Hot reload
- `mix firmware.reboot && mix upload IP` - Full reboot

## How It Works

### Update Process Flow

```
1. Upload firmware via SSH (mix upload IP)
   ↓
2. fwup writes firmware to inactive partition
   ↓
3. fwup updates boot configuration (U-Boot/MBR)
   ↓
4. ssh_subsystem_fwup calls NervesZeroDowntime.handle_firmware_update/0
   ↓
5. Mount inactive partition read-only
   ↓
6. Check for HOT_RELOAD marker file
   ├─→ HOT_RELOAD=false or missing? → REBOOT
   └─→ HOT_RELOAD=true? → Continue to hot reload
   ↓
7. Discover BEAM files on mounted partition
   ↓
8. Filter modules (only reload application code, not OTP/Elixir core)
   ↓
9. Hot reload modules:
    - Purge old code
    - Load new code directly from mounted partition
    - Validate reload success
   ↓
10. If reload succeeds:
    - Mark firmware as validated
    - Device running new code (zero downtime!)
    - Ready to boot new partition on any reboot
   ↓
11. If reload fails:
    - Attempt rollback to previous code
    - If rollback fails: Reboot to new partition
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
- Writable `/data` partition (for programmatic updates only; SSH uploads load directly from partition)
- `fwup` utility available on device
- Elixir 1.13 or later

## Limitations

- Only works for application-level code changes
- Requires sufficient disk space on `/data` partition
- NIF changes require reboot (cannot hot-reload native code)
- Relup support is planned but not yet implemented
- Currently uses simple module reload (not full OTP release upgrades)

## License

Copyright 2024 Big Cove Technology

All rights reserved. This code is proprietary and not licensed for public use.

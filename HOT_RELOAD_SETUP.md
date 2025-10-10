# Hot Reload Setup Guide

To enable hot reload for your Nerves firmware, you need to include a `HOT_RELOAD` marker file in your rootfs.

## Method 1: Mix Tasks (Recommended)

The easiest way is to use the provided mix tasks:

### Enable Hot Reload

```bash
# Enable hot reload for next firmware build
mix firmware.enable_reload

# Build and upload
mix firmware
mix firmware.upload IP
```

This creates `rootfs_overlay/srv/erlang/HOT_RELOAD` with content "true".

### Require Reboot

```bash
# Require full reboot for next firmware build
mix firmware.require_reboot

# Build and upload
mix firmware
mix firmware.upload IP
```

This creates `rootfs_overlay/srv/erlang/HOT_RELOAD` with content "false".

### Combined Commands

```bash
# Hot reload build
mix firmware.enable_reload && mix firmware && mix firmware.upload IP

# Reboot build
mix firmware.require_reboot && mix firmware && mix firmware.upload IP
```

## Method 2: Manual rootfs_overlay

1. **Create overlay directory** in your project:
   ```bash
   mkdir -p rootfs_overlay/srv/erlang
   ```

2. **Create the HOT_RELOAD marker file**:
   ```bash
   # For hot reload
   echo "true" > rootfs_overlay/srv/erlang/HOT_RELOAD

   # For reboot
   echo "false" > rootfs_overlay/srv/erlang/HOT_RELOAD
   ```

3. **Build firmware**:
   ```bash
   mix firmware
   mix firmware.upload IP
   ```

## Method 3: Mix Aliases

You can create aliases in your project's `mix.exs` for convenience:

```elixir
defp aliases do
  [
    "firmware.hot": ["firmware.enable_reload", "firmware"],
    "firmware.reboot": ["firmware.require_reboot", "firmware"]
  ]
end
```

Then use:

```bash
# Hot reload build
mix firmware.hot

# Reboot build
mix firmware.reboot
```

## Verification

After uploading firmware, check the device logs:

```bash
# SSH into device
ssh device_ip

# Check RingLogger
iex> RingLogger.tail
# You'll see either:
# [info] Found HOT_RELOAD=true - firmware supports hot reload
# or
# [info] Found HOT_RELOAD=false - firmware requires reboot
```

## HOT_RELOAD File Format

The `HOT_RELOAD` file must contain exactly one of:
- `true` - Enable hot reload
- `false` - Require reboot

Any other content will be treated as invalid and the firmware will reboot.

## When to Use Hot Reload vs Reboot

### Use Hot Reload (`mix firmware.enable_reload`)

- Application code changes
- Business logic updates
- Bug fixes
- New features
- Dependency updates (same OTP/Elixir version)

### Require Reboot (`mix firmware.require_reboot`)

- Kernel updates
- ERTS/OTP version changes
- Elixir version changes
- nerves_system_* updates
- When you want guaranteed clean state

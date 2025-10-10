## Testing Hot Reload

This guide shows how to test hot reload functionality on a running Nerves device.

### Integration Test

1. **Make a code change** in your application

2. **Increment the version** in `mix.exs`:
   ```elixir
   @version "0.1.8"  # Was 0.1.7
   ```

3. **Build firmware**:
   ```bash
   mix firmware
   ```

4. **Upload firmware**:
   ```bash
   mix firmware.upload 192.168.1.100
   ```

6. **Watch the logs** on the device:
   ```elixir
   ssh 192.168.1.100
   RingLogger.tail
   ```

   You should see:
   ```
   [info] Firmware update completed via SSH, determining update strategy
   [info] Checking if staged firmware can be hot-reloaded
   [info] Reading firmware metadata from inactive partition
   [info] Mounting /dev/mmcblk0p3 at /tmp/inactive_partition
   [info] Staged firmware can be hot reloaded
   [info] Preparing hot reload from staged version 0.1.8
   [info] Reloading 42 modules
   [info] Hot reload completed successfully
   [info] Firmware hot-reloaded successfully
   ```

   For a reboot scenario (e.g., kernel changed):
   ```
   [info] Reading firmware metadata from inactive partition
   [info] Staged firmware requires reboot: [:kernel_version_changed]
   [info] Rebooting to new firmware...
   ```

### Troubleshooting

#### "Failed to mount partition"

The system couldn't mount the inactive partition. Check:
1. Is the partition device path correct? Look for logs showing the device path
2. Does your kernel support the filesystem? (squashfs/ext4)
3. Try manually: `mount -t squashfs -o ro /dev/mmcblk0p3 /tmp/test`

#### "Could not find meta.conf"

The metadata file wasn't found in expected locations. Check:
1. Is this a standard Nerves system?
2. Where does your system store meta.conf? (usually `/srv/erlang/meta.conf`)
3. Try: `mount -o ro /dev/mmcblk0p3 /tmp/test && find /tmp/test -name meta.conf`

#### "Hot reload failed"

Check detailed error logs:
```elixir
RingLogger.tail(1000)  # Show more history
```

Common issues:
- Missing BEAM files in bundle
- Incorrect module names
- Syntax errors in new code

#### Hot reload succeeds but code doesn't change

Verify modules were actually reloaded:
```elixir
# Get module info
{:module, MyApp.MyModule}
:code.which(MyApp.MyModule)  # Should show path to new BEAM file

# Check module compilation time
{:ok, {MyApp.MyModule, [{:compile_time, {date, time}}]}} =
  :beam_lib.chunks(:code.which(MyApp.MyModule), [:compile_time])
```

### Manual Rollback Test

Test the rollback mechanism:

```elixir
# After a hot reload, trigger rollback
NervesZeroDowntime.rollback()

# Should restore previous version
```

### Performance Testing

Measure hot reload time:

```elixir
:timer.tc(fn ->
  NervesZeroDowntime.TestHelper.simulate_ssh_callback()
  Process.sleep(5000)  # Wait for completion
end)
|> elem(0)
|> Kernel./(1_000_000)  # Convert to seconds
```

Typical hot reload time: 1-5 seconds depending on:
- Number of modules
- Size of BEAM files
- Device performance

Compare to reboot time: 30-60 seconds.

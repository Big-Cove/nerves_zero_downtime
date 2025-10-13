defmodule Mix.Tasks.Firmware.EnableReload do
  use Mix.Task

  @shortdoc "Enable hot code reloading for next firmware build"

  @moduledoc """
  Enables hot code reloading for the next firmware build.

  This task creates a `rootfs_overlay/srv/erlang/HOT_RELOAD` file with the
  content "true". When this firmware is uploaded to a device, it will attempt
  to hot reload the application code without rebooting.

  ## Usage

      mix firmware.enable_reload
      mix firmware

  Or combine with firmware task:

      mix firmware.enable_reload && mix firmware

  ## When to Use

  Use this when you're making **application-level changes only**:
  - Business logic updates
  - Bug fixes
  - New features in your application code
  - Dependency updates (that don't change OTP/Elixir versions)

  ## When NOT to Use

  Do NOT use this when making **system-level changes**:
  - Kernel updates
  - ERTS/OTP version changes
  - Elixir version changes
  - Critical dependency changes (e.g., nerves_system_*)

  For system-level changes, use `mix firmware.require_reboot` instead.

  ## See Also

  - `mix firmware.require_reboot` - Disable hot reload and require full reboot
  """

  @impl Mix.Task
  def run(_args) do
    marker_dir = "rootfs_overlay/srv/erlang"
    marker_path = Path.join(marker_dir, "HOT_RELOAD")

    # Ensure directory exists
    File.mkdir_p!(marker_dir)

    # Write "true" to marker file
    File.write!(marker_path, "true")

    Mix.shell().info("""
    ✓ Hot reload ENABLED for next firmware build

    Changes made:
    - #{marker_path} set to "true"

    When this firmware is uploaded, the device will:
    1. Write firmware to inactive partition
    2. Attempt hot code reload without rebooting
    3. Fall back to reboot if hot reload fails

    Next steps:
      mix firmware         # Build firmware with hot reload enabled
      mix upload           # Upload to device
    """)
  end
end

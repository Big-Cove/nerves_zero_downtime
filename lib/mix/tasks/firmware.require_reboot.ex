defmodule Mix.Tasks.Firmware.RequireReboot do
  use Mix.Task

  @shortdoc "Require full reboot for next firmware build"

  @moduledoc """
  Requires a full reboot for the next firmware build.

  This task creates a `rootfs_overlay/srv/erlang/HOT_RELOAD` file with the
  content "false". When this firmware is uploaded to a device, it will
  reboot to activate the new firmware instead of attempting hot reload.

  ## Usage

      mix firmware.require_reboot
      mix firmware

  Or combine with firmware task:

      mix firmware.require_reboot && mix firmware

  ## When to Use

  Use this when you're making **system-level changes**:
  - Kernel updates
  - ERTS/OTP version changes
  - Elixir version changes
  - Critical dependency changes (e.g., nerves_system_*)
  - Any change where you want to ensure a clean reboot

  ## When NOT to Use

  For simple application-level changes (business logic, bug fixes, new features),
  use `mix firmware.enable_reload` instead to avoid downtime.

  ## See Also

  - `mix firmware.enable_reload` - Enable hot reload for application changes
  """

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Disabling hot reload, requiring full reboot...\n")

    marker_dir = "rootfs_overlay/srv/erlang"
    marker_path = Path.join(marker_dir, "HOT_RELOAD")

    # Ensure directory exists
    File.mkdir_p!(marker_dir)

    # Write "false" to marker file
    File.write!(marker_path, "false")

    Mix.shell().info("""
    ✅ Full reboot REQUIRED for next firmware build

    Changes made:
    - #{marker_path} set to "false"

    When this firmware is uploaded, the device will:
    1. Write firmware to inactive partition
    2. Reboot to activate new firmware

    Next steps:
      mix firmware         # Build firmware with reboot required
      mix upload           # Upload to device

    💡 Note: This only disables hot reload. The A/B/C partition configuration
    remains in place. To completely remove custom fwup configuration, delete:
    - fwup.conf
    - fwup_include/
    And remove fwup_conf setting from config/target.exs
    """)
  end
end

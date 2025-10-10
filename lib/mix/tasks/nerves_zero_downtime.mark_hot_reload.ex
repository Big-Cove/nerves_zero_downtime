defmodule Mix.Tasks.NervesZeroDowntime.MarkHotReload do
  @moduledoc """
  Marks the current release as hot-reload capable.

  This task creates a HOT_RELOAD marker file in the release output directory
  that will be included in the firmware. When this marker is present, the
  system will attempt hot code reload instead of rebooting.

  ## Usage

      # Mark the release as hot-reload capable
      mix nerves_zero_downtime.mark_hot_reload

      # Then build firmware as normal
      mix firmware

  ## When to use this

  Mark your release as hot-reload capable when you've ONLY changed:
  - Application code (Elixir/Erlang modules)
  - Configuration
  - Dependencies (pure Elixir/Erlang libs)

  DO NOT mark as hot-reload capable if you changed:
  - Kernel version
  - ERTS/OTP version
  - NIFs or native libraries
  - System dependencies

  ## Marker file format

  The marker file is JSON with optional metadata:

      {
        "hot_reload": true,
        "version": "1.2.3",
        "timestamp": "2025-01-10T12:00:00Z"
      }

  ## Integration

  You can add this to your firmware build aliases:

      defp aliases do
        [
          "firmware.hot": ["nerves_zero_downtime.mark_hot_reload", "firmware"],
          "firmware": ["compile", "firmware"]  # Regular firmware, no hot reload
        ]
      end

  Then use:
  - `mix firmware.hot` - For hot-reloadable updates
  - `mix firmware` - For updates requiring reboot
  """

  @shortdoc "Mark release as hot-reload capable"

  use Mix.Task

  require Logger

  @impl Mix.Task
  def run(_args) do
    # Set environment variable that will persist for subsequent Mix tasks
    System.put_env("NERVES_HOT_RELOAD", "true")

    Mix.shell().info("✓ Hot reload enabled for this build")
    Mix.shell().info("  Use: mix firmware.hot (or manually: export NERVES_HOT_RELOAD=true && mix firmware)")
  end
end

defmodule NervesZeroDowntime do
  @moduledoc """
  Zero-downtime firmware updates for Nerves devices.

  This library enables firmware updates without rebooting for application-level changes,
  while maintaining the safety guarantees of A/B partition updates.

  ## Key Features

  - **Zero downtime** for application code updates
  - **Safety first** - partitions always updated, ready to boot on any reboot
  - **Automatic detection** - determines if hot reload is safe or reboot is required
  - **Rollback support** - automatic rollback on failure
  - **Validation** - health checks before and after updates

  ## Usage

  ### Basic Update

      # Apply firmware update (auto-detects hot reload vs reboot)
      NervesZeroDowntime.apply_update("/path/to/firmware.fw")

  ### Check Status

      # Get current update status
      NervesZeroDowntime.status()

  ### Force Reboot

      # Force full reboot even if hot reload capable
      NervesZeroDowntime.apply_update("/path/to/firmware.fw", force_reboot: true)

  ### Manual Rollback

      # Rollback to previous version
      NervesZeroDowntime.rollback()

  ## Architecture

  The update process:

  1. Write firmware to inactive partition (via fwup)
  2. Update boot configuration (U-Boot env / MBR)
  3. Analyze firmware for hot reload compatibility
  4. If safe: Hot reload application code from /data
  5. If not safe: Reboot to new partition

  This ensures that even if hot reloading, the device is always ready to boot
  into the new firmware on any unexpected reboot or power loss.

  ## Requirements

  - Nerves system with A/B partition support
  - Writable /data partition
  - fwup utility available
  - Sufficient disk space in /data (minimum 100MB recommended)

  ## Integration

  Add to your application's supervision tree:

      def start(_type, _args) do
        children = [
          # Your application children...
          NervesZeroDowntime
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  Configure SSH subsystem to use zero-downtime updates:

      config :ssh_subsystem_fwup,
        success_callback: {NervesZeroDowntime, :handle_firmware_update, []}

  """

  require Logger

  alias NervesZeroDowntime.{Orchestrator, FirmwareStager, Validator, BootedPartition}

  @doc """
  Apply a firmware update.

  ## Options

  - `:force_reboot` - Force full reboot even if hot reload capable (default: false)
  - `:dry_run` - Analyze but don't execute update (default: false)

  ## Returns

  - `{:ok, :hot_reloaded}` - Successfully hot reloaded
  - `{:ok, :rebooting}` - Reboot required, system rebooting
  - `{:error, reason}` - Update failed

  ## Examples

      # Standard update
      NervesZeroDowntime.apply_update("/tmp/firmware.fw")

      # Force reboot
      NervesZeroDowntime.apply_update("/tmp/firmware.fw", force_reboot: true)

      # Dry run
      NervesZeroDowntime.apply_update("/tmp/firmware.fw", dry_run: true)
  """
  @spec apply_update(Path.t(), keyword()) :: Orchestrator.update_result()
  defdelegate apply_update(firmware_path, opts \\ []), to: Orchestrator

  @doc """
  Get current update status and history.

  ## Returns

  A map containing:
  - `:current_version` - Currently running version
  - `:partition_active` - Active partition ("a" or "b")
  - `:last_update` - Timestamp of last successful update
  - `:pending_hot_reload` - Whether a hot reload is staged
  - `:update_history` - Recent update history

  ## Examples

      NervesZeroDowntime.status()
      #=> %{
        current_version: "1.0.0",
        partition_active: "a",
        last_update: 1699564800,
        pending_hot_reload: false,
        update_history: [...]
      }
  """
  @spec status() :: map()
  defdelegate status(), to: Orchestrator

  @doc """
  Check if hot reload is currently available.

  ## Returns

  `true` if a staged update can be hot-reloaded, `false` otherwise.

  ## Examples

      if NervesZeroDowntime.hot_reload_available?() do
        Logger.info("Can hot reload")
      end
  """
  @spec hot_reload_available?() :: boolean()
  defdelegate hot_reload_available?(), to: Orchestrator

  @doc """
  Manually trigger reboot to new partition.

  This is useful if you've staged an update but want to manually
  control when the reboot happens.

  ## Examples

      NervesZeroDowntime.reboot_to_new_partition()
  """
  @spec reboot_to_new_partition() :: no_return()
  defdelegate reboot_to_new_partition(), to: Orchestrator

  @doc """
  Rollback to previous version.

  This attempts to rollback a hot-reloaded update. If the rollback
  fails, the system will reboot to the previous partition.

  ## Returns

  - `:ok` - Rollback successful
  - `{:error, reason}` - Rollback failed (system may reboot)

  ## Examples

      case NervesZeroDowntime.rollback() do
        :ok -> Logger.info("Rolled back successfully")
        {:error, reason} -> Logger.error("Rollback failed: \#{inspect(reason)}")
      end
  """
  @spec rollback() :: :ok | {:error, term()}
  defdelegate rollback(), to: Orchestrator

  @doc """
  Callback for SSH firmware update subsystem.

  This can be used as the success_callback for ssh_subsystem_fwup
  to enable zero-downtime updates over SSH.

  When this callback is invoked, fwup has already written the firmware
  to the inactive partition. This function determines whether to hot
  reload the application code or reboot to the new partition.

  ## Configuration

      config :ssh_subsystem_fwup,
        success_callback: {NervesZeroDowntime, :handle_firmware_update, []}
  """
  @spec handle_firmware_update() :: :ok
  def handle_firmware_update do
    Logger.info("Firmware update completed via SSH, determining update strategy")

    # At this point, fwup has already:
    # 1. Written firmware to inactive partition
    # 2. Updated boot configuration (u-boot environment)
    # The firmware is staged and ready to boot on next reboot.
    #
    # IMPORTANT: We need to reload the u-boot environment because Nerves.Runtime.KV
    # caches it at boot time. After fwup modifies the u-boot env, the cache is stale.
    # Tell the KV GenServer to reload by stopping and restarting it.
    Logger.debug("Reloading u-boot environment after fwup update")
    Supervisor.terminate_child(Nerves.Runtime.Supervisor, Nerves.Runtime.KV)
    Supervisor.restart_child(Nerves.Runtime.Supervisor, Nerves.Runtime.KV)

    # Now we need to decide: hot reload or reboot?
    spawn(fn ->
      case determine_and_apply_staged_update() do
        {:ok, :hot_reloaded} ->
          Logger.info("Firmware hot-reloaded successfully")
          # Mark firmware as validated
          Nerves.Runtime.validate_firmware()
          # Update booted partition metadata to reflect new version
          BootedPartition.update_booted_partition_metadata()

        {:ok, :rebooting} ->
          Logger.info("Rebooting to new firmware...")

        {:error, reason} ->
          Logger.error("Failed to apply staged firmware: #{inspect(reason)}, rebooting as fallback")
          # Fallback: reboot to new partition
          Process.sleep(1000)
          Nerves.Runtime.reboot()
      end
    end)

    :ok
  end

  @doc false
  def determine_and_apply_staged_update do
    Logger.info("Checking if staged firmware can be hot-reloaded")

    with {:ok, firmware_info} <- FirmwareStager.check_staged_firmware(),
         :ok <- Validator.pre_update_checks(),
         {:ok, :hot_reloaded} <- FirmwareStager.apply_staged_firmware(firmware_info),
         :ok <- Validator.post_update_validation() do
      Logger.info("Hot reload completed successfully")
      {:ok, :hot_reloaded}
    else
      {:error, :reboot_required} ->
        Logger.info("Firmware not marked for hot reload, rebooting")
        schedule_reboot()
        {:ok, :rebooting}

      {:error, :no_hot_reload_marker} ->
        Logger.info("No hot reload marker found, rebooting")
        schedule_reboot()
        {:ok, :rebooting}

      {:error, reason} ->
        Logger.warning("Hot reload check/apply failed: #{inspect(reason)}, defaulting to reboot")
        schedule_reboot()
        {:ok, :rebooting}
    end
  end

  defp schedule_reboot do
    spawn(fn ->
      Process.sleep(1000)
      Nerves.Runtime.reboot()
    end)
  end
end

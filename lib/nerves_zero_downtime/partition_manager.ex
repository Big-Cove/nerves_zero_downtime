defmodule NervesZeroDowntime.PartitionManager do
  @moduledoc """
  Manages partition updates while preserving hot reload capability.

  This module coordinates with fwup to:
  1. Write firmware to inactive partition
  2. Update U-Boot environment variables / MBR
  3. Mark firmware as pending hot reload (don't trigger immediate reboot)
  """

  require Logger

  @doc """
  Prepare partition update.

  This runs fwup to write the firmware to the inactive partition and
  update boot configuration, but does NOT trigger a reboot.
  """
  @spec prepare_update(Path.t(), map()) :: :ok | {:error, term()}
  def prepare_update(firmware_path, metadata) do
    Logger.info("Preparing partition update for #{metadata.to_version}")

    devpath = get_device_path()
    task = get_fwup_task(metadata)

    with :ok <- validate_firmware(firmware_path),
         :ok <- run_fwup(firmware_path, devpath, task),
         :ok <- mark_pending_hot_reload(metadata.to_version) do
      Logger.info("Partition update prepared successfully")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Partition update failed: #{inspect(reason)}")
        error
    end
  end

  # Private functions

  defp get_device_path do
    Nerves.Runtime.KV.get("nerves_fw_devpath") || "/dev/mmcblk0"
  end

  defp get_fwup_task(_metadata) do
    # Use standard upgrade task for now
    # In the future, could use "upgrade_no_reboot" task
    "upgrade"
  end

  defp validate_firmware(firmware_path) do
    if File.exists?(firmware_path) do
      :ok
    else
      {:error, :firmware_file_not_found}
    end
  end

  defp run_fwup(firmware_path, devpath, task) do
    fwup_path = System.find_executable("fwup") || "/usr/bin/fwup"

    args = [
      "--apply",
      "--no-unmount",
      "-d", devpath,
      "--task", task,
      "-i", firmware_path
    ]

    Logger.debug("Running: #{fwup_path} #{Enum.join(args, " ")}")

    case System.cmd(fwup_path, args, stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("fwup output: #{output}")
        :ok

      {output, exit_code} ->
        Logger.error("fwup failed with exit code #{exit_code}: #{output}")
        {:error, {:fwup_failed, exit_code, output}}
    end
  end

  defp mark_pending_hot_reload(version) do
    # Set U-Boot env variable to indicate hot reload is pending
    # This helps detect if we reboot before hot reload completes
    try do
      UBootEnv.write(%{
        "nerves_fw_pending_hot_reload" => "1",
        "nerves_fw_pending_version" => version
      })

      :ok
    rescue
      e ->
        Logger.warning("Could not set pending hot reload flag: #{inspect(e)}")
        # Non-fatal - continue anyway
        :ok
    end
  end
end

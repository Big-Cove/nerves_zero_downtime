defmodule NervesZeroDowntime.FirmwareStager do
  @moduledoc """
  Manages staged firmware for hot reload detection.

  After fwup completes writing firmware to the inactive partition,
  this module reads metadata and extracts the hot reload bundle
  directly from that partition.

  This module provides utilities to:
  1. Read metadata from the inactive partition
  2. Extract hot reload bundle from the inactive partition
  3. Determine if hot reload is possible for staged firmware
  """

  require Logger

  alias NervesZeroDowntime.{HotReload, PartitionReader}

  @doc """
  Check if there is staged firmware ready for hot reload.

  Reads the HOT_RELOAD marker file from the inactive partition.
  If present, the firmware can be hot reloaded. If absent, requires reboot.

  Returns `{:ok, {metadata, mount_point}}` if staged firmware
  exists and can be hot reloaded, or `{:error, reason}` otherwise.
  """
  @spec check_staged_firmware() :: {:ok, {map(), Path.t()}} | {:error, term()}
  def check_staged_firmware do
    Logger.info("Checking inactive partition for hot reload capability")

    case PartitionReader.extract_from_inactive_partition() do
      {:ok, {metadata, mount_point}} ->
        Logger.info("Firmware is marked as hot-reload capable")
        {:ok, {metadata, mount_point}}

      {:error, :no_hot_reload_marker} ->
        Logger.info("Firmware is not marked for hot reload - will reboot")
        PartitionReader.cleanup()
        {:error, :reboot_required}

      {:error, reason} = error ->
        Logger.warning("Failed to check firmware: #{inspect(reason)} - will reboot")
        PartitionReader.cleanup()
        error
    end
  end

  @doc """
  Apply staged firmware via hot reload.

  This assumes check_staged_firmware/0 has already verified the update is safe.

  The process:
  1. Copy BEAM files from mounted partition to /data staging area
  2. Unmount the partition (files now safely in /data)
  3. Load modules from /data staging area
  """
  @spec apply_staged_firmware({map(), Path.t()}) :: {:ok, :hot_reloaded} | {:error, term()}
  def apply_staged_firmware({metadata, mount_point}) do
    version = metadata["version"] || metadata[:version] || "unknown"

    Logger.info("Applying hot reload for version #{version}")

    result =
      with {:ok, staging_path} <- HotReload.prepare_from_partition(mount_point, version) do
        # Cleanup (unmount) BEFORE loading modules - files are now in /data
        Logger.debug("Unmounting partition before hot reload")
        PartitionReader.cleanup()

        # Now safely load from /data staging area
        case HotReload.apply(staging_path, version) do
          {:ok, :hot_reloaded} ->
            {:ok, :hot_reloaded}

          {:error, reason} = error ->
            Logger.error("Failed to apply staged firmware: #{inspect(reason)}")
            error
        end
      else
        {:error, reason} = error ->
          Logger.error("Failed to prepare staged firmware: #{inspect(reason)}")
          PartitionReader.cleanup()
          error
      end

    result
  end

end

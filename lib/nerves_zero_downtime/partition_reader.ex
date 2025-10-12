defmodule NervesZeroDowntime.PartitionReader do
  @moduledoc """
  Reads firmware content from the inactive partition.

  After fwup completes, the new firmware is written to the inactive
  partition. This module mounts that partition read-only and extracts
  the metadata and hot reload bundle needed for hot reload detection.

  This is much cleaner than requiring fwup.conf modifications - we
  simply read what's already been written to the partition.
  """

  require Logger

  @mount_point "/data/inactive_partition"

  @doc """
  Extract metadata from the inactive partition.

  Returns `{:ok, {metadata, mount_point}}` on success.
  The mount point remains mounted so BEAM files can be read directly from it.
  """
  @spec extract_from_inactive_partition() ::
          {:ok, {map(), Path.t()}} | {:error, term()}
  def extract_from_inactive_partition do
    Logger.info("Reading firmware from inactive partition")

    with {:ok, inactive_dev} <- get_inactive_partition_device(),
         {:ok, mount_point} <- mount_partition(inactive_dev),
         {:ok, metadata} <- read_metadata_from_mount(mount_point) do
      # Keep partition mounted - we'll read BEAM files directly from it
      Logger.info("Successfully read firmware from inactive partition")
      {:ok, {metadata, mount_point}}
    else
      {:error, reason} = error ->
        Logger.error("Failed to read from inactive partition: #{inspect(reason)}")
        # Ensure cleanup
        unmount_partition()
        error
    end
  end

  @doc """
  Clean up mounted partition.
  """
  @spec cleanup() :: :ok
  def cleanup do
    unmount_partition()
  end

  # Private functions

  defp get_inactive_partition_device do
    # Get current active partition from Nerves.Runtime.KV
    kv = Nerves.Runtime.KV.get_all()
    active = kv["nerves_fw_active"]

    # In a 3-partition system (A/B/C), after firmware is written and boot pointer updated,
    # the inactive partition is the one that the boot pointer now points to (where the new firmware is).
    # The system is still running from the original partition.
    #
    # Example: Running from A, boot pointer updated to B → we want to hot reload from B
    # Example: Running from A (still), boot pointer updated to C → we want to hot reload from C
    #
    # The "active" variable tells us where the boot pointer is (not where we're currently running from).
    # So we want to mount and hot reload from the "active" partition, not the "inactive" one.
    #
    # This is counterintuitive but correct: after fwup writes to the "inactive" partition and updates
    # the boot pointer, that partition becomes "active" in the u-boot environment, even though we're
    # still running from the previous partition.
    target_letter = active

    if target_letter do
      # Extract the rootfs device from kernel_args for the target partition
      # Example: "b.kernel_args" => "root=/dev/vda5 rootfstype=squashfs"
      kernel_args = kv["#{target_letter}.kernel_args"]

      case extract_root_device(kernel_args) do
        {:ok, device} ->
          Logger.debug("Target partition (#{target_letter}) rootfs device: #{device}")
          {:ok, device}

        {:error, reason} ->
          Logger.error("Could not determine target rootfs device: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.error("Could not determine target partition")
      {:error, :unknown_active_partition}
    end
  end

  defp extract_root_device(kernel_args) when is_binary(kernel_args) do
    # Parse kernel_args like "root=/dev/vda2 rootfstype=squashfs"
    case Regex.run(~r/root=(\/dev\/[^\s]+)/, kernel_args) do
      [_, device] ->
        if File.exists?(device) do
          {:ok, device}
        else
          {:error, {:device_not_found, device}}
        end

      nil ->
        {:error, :root_device_not_in_kernel_args}
    end
  end

  defp extract_root_device(_), do: {:error, :missing_kernel_args}

  defp mount_partition(device) do
    # Create mount point
    File.mkdir_p!(@mount_point)

    # Verify device node exists and is a block device (log only, don't fail)
    Logger.debug("Verifying device #{device} before mount")
    case File.stat(device) do
      {:ok, %File.Stat{type: :device}} ->
        Logger.debug("Device #{device} verified as block device")
      {:ok, %File.Stat{type: type}} ->
        Logger.warning("Device #{device} exists but is type #{type}, not :device")
      {:error, reason} ->
        Logger.error("Cannot stat device #{device}: #{inspect(reason)}")
    end

    # Try to mount as squashfs (most Nerves systems use squashfs for rootfs)
    Logger.debug("Mounting #{device} at #{@mount_point}")

    case System.cmd("mount", ["-t", "squashfs", "-o", "ro", device, @mount_point],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Logger.debug("Partition mounted successfully")
        # Verify mount point is accessible
        verify_mount_accessible()

      {output, _code} ->
        Logger.error("Failed to mount partition: #{output}")

        # Try without specifying filesystem type
        case System.cmd("mount", ["-o", "ro", device, @mount_point],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            Logger.debug("Partition mounted successfully (auto fs type)")
            verify_mount_accessible()

          {output2, code2} ->
            Logger.error("Mount failed: #{output2}")
            {:error, {:mount_failed, code2, output2}}
        end
    end
  end

  defp verify_mount_accessible do
    # Wait a moment for filesystem to stabilize
    Process.sleep(100)

    # Verify we can list the mount point
    case File.ls(@mount_point) do
      {:ok, files} ->
        Logger.debug("Mount point accessible, contains #{length(files)} entries")
        {:ok, @mount_point}
      {:error, reason} ->
        Logger.error("Mount point not accessible: #{inspect(reason)}")
        {:error, {:mount_not_accessible, reason}}
    end
  end

  defp unmount_partition do
    if File.exists?(@mount_point) do
      Logger.debug("Unmounting #{@mount_point}")

      case System.cmd("umount", [@mount_point], stderr_to_stdout: true) do
        {_, 0} ->
          File.rm_rf(@mount_point)
          :ok

        {output, _} ->
          Logger.warning("Unmount failed: #{output}")
          # Force unmount
          System.cmd("umount", ["-f", @mount_point], stderr_to_stdout: true)
          File.rm_rf(@mount_point)
          :ok
      end
    else
      :ok
    end
  end

  defp read_metadata_from_mount(mount_point) do
    Logger.info("Checking for hot reload marker in mounted partition")

    # Check for hot reload marker file
    marker_path = Path.join([mount_point, "srv", "erlang", "HOT_RELOAD"])

    case File.read(marker_path) do
      {:ok, content} ->
        content_trimmed = String.trim(content)

        case content_trimmed do
          "true" ->
            Logger.info("Found HOT_RELOAD=true - firmware supports hot reload")
            {:ok, %{"hot_reload" => true}}

          "false" ->
            Logger.info("Found HOT_RELOAD=false - firmware requires reboot")
            {:error, :reboot_required}

          _ ->
            Logger.warning("HOT_RELOAD file has invalid content: #{inspect(content_trimmed)}, expected 'true' or 'false' - defaulting to reboot")
            {:error, :invalid_marker}
        end

      {:error, :enoent} ->
        Logger.info("No HOT_RELOAD marker found - firmware requires reboot")
        {:error, :no_hot_reload_marker}

      {:error, reason} ->
        Logger.error("Error reading HOT_RELOAD marker: #{inspect(reason)}")
        {:error, {:marker_read_failed, reason}}
    end
  end


end

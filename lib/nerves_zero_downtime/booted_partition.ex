defmodule NervesZeroDowntime.BootedPartition do
  @moduledoc """
  Detects which partition the kernel booted from.

  This is critical for 3-partition hot reload systems where:
  - `nerves_fw_booted` = partition where kernel booted from (NEVER changes during hot reloads, read from /proc/cmdline)
  - `nerves_fw_active` = boot pointer (where system will boot next, updated by fwup)

  The booted partition is determined once at startup by reading /proc/cmdline
  and stored in the u-boot environment. It never changes during hot reloads,
  even though we load code from other partitions.
  """

  require Logger

  @doc """
  Initialize the nerves_fw_booted marker by reading from /proc/cmdline.

  This should be called once at startup. The booted partition never changes
  during hot reloads, even when we load code from other partitions.

  This function is idempotent - it only updates nerves_fw_booted if it differs
  from the actual boot partition (from /proc/cmdline).
  """
  @spec initialize_booted_partition() :: :ok | {:error, term()}
  def initialize_booted_partition do
    case get_boot_partition() do
      nil ->
        Logger.error("Could not determine boot partition from /proc/cmdline")
        {:error, :unknown_partition}

      partition ->
        # Check if nerves_fw_booted is already set correctly
        kv = Nerves.Runtime.KV.get_all()
        current_booted = kv["nerves_fw_booted"]

        if current_booted == partition do
          Logger.debug("nerves_fw_booted already set correctly to: #{partition}")
          :ok
        else
          Logger.info("Initializing nerves_fw_booted to: #{partition} (was: #{inspect(current_booted)})")

          case System.cmd("fw_setenv", ["nerves_fw_booted", partition], stderr_to_stdout: true) do
            {_, 0} ->
              # Reload KV cache to pick up the new value
              Supervisor.terminate_child(Nerves.Runtime.Supervisor, Nerves.Runtime.KV)
              Supervisor.restart_child(Nerves.Runtime.Supervisor, Nerves.Runtime.KV)
              :ok

            {output, code} ->
              Logger.error("Failed to set nerves_fw_booted: #{output}")
              {:error, {:fw_setenv_failed, code}}
          end
        end
    end
  end

  @doc """
  Update the booted partition's firmware metadata after hot reload.

  After a successful hot reload, we need to copy the firmware metadata from
  the active partition to the booted partition so that the version info is current.
  This ensures tools like NervesMOTD show the correct version.
  """
  @spec update_booted_partition_metadata() :: :ok | {:error, term()}
  def update_booted_partition_metadata do
    kv = Nerves.Runtime.KV.get_all()
    booted = kv["nerves_fw_booted"]
    active = kv["nerves_fw_active"]

    if booted && active && booted != active do
      Logger.info("Updating #{booted} partition metadata from #{active} after hot reload")

      # Copy key firmware metadata from active partition to booted partition
      metadata_keys = [
        "nerves_fw_version",
        "nerves_fw_uuid",
        "nerves_fw_vcs_identifier",
        "nerves_fw_misc"
      ]

      results = Enum.map(metadata_keys, fn key ->
        source_key = "#{active}.#{key}"
        dest_key = "#{booted}.#{key}"

        case kv[source_key] do
          nil ->
            Logger.debug("Skipping #{key} - not set in active partition")
            :ok

          value ->
            case System.cmd("fw_setenv", [dest_key, value], stderr_to_stdout: true) do
              {_, 0} ->
                Logger.debug("Updated #{dest_key} = #{value}")
                :ok

              {output, code} ->
                Logger.error("Failed to set #{dest_key}: #{output}")
                {:error, {:fw_setenv_failed, code, dest_key}}
            end
        end
      end)

      # Reload KV cache to pick up the new values
      Supervisor.terminate_child(Nerves.Runtime.Supervisor, Nerves.Runtime.KV)
      Supervisor.restart_child(Nerves.Runtime.Supervisor, Nerves.Runtime.KV)

      # Check if any updates failed
      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> :ok
        error -> error
      end
    else
      Logger.debug("Skipping metadata update - booted and active are the same")
      :ok
    end
  end

  @doc """
  Get the partition the kernel booted from by reading /proc/cmdline.

  Returns "a", "b", "c", or nil if unable to determine.
  """
  @spec get_boot_partition() :: String.t() | nil
  def get_boot_partition do
    case File.read("/proc/cmdline") do
      {:ok, cmdline} ->
        parse_root_device(cmdline)

      {:error, reason} ->
        Logger.error("Failed to read /proc/cmdline: #{inspect(reason)}")
        nil
    end
  end

  # Private functions

  defp parse_root_device(cmdline) do
    # Parse cmdline like: "root=/dev/vda1 rootfstype=squashfs ..."
    # or "root=/dev/vda5 rootfstype=squashfs ..."
    # Map device to partition letter:
    #   /dev/vda1 -> a
    #   /dev/vda5 -> b (logical partition 5 in MBR)
    #   /dev/vda6 -> c (logical partition 6 in MBR)

    case Regex.run(~r/root=(\/dev\/[^\s]+)/, cmdline) do
      [_, device] ->
        device_to_partition(device)

      nil ->
        Logger.error("Could not find root= in cmdline: #{cmdline}")
        nil
    end
  end

  defp device_to_partition("/dev/vda1"), do: "a"
  defp device_to_partition("/dev/vda2"), do: "b"
  defp device_to_partition("/dev/vda5"), do: "c"

  # Support other device naming schemes
  defp device_to_partition("/dev/mmcblk0p1"), do: "a"
  defp device_to_partition("/dev/mmcblk0p2"), do: "b"
  defp device_to_partition("/dev/mmcblk0p5"), do: "c"

  defp device_to_partition(device) do
    Logger.warning("Unknown root device: #{device}, cannot determine partition")
    nil
  end
end

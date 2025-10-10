defmodule NervesZeroDowntime.Orchestrator do
  @moduledoc """
  Orchestrates zero-downtime firmware updates combining
  partition updates with hot code reloading.

  This module coordinates the entire update process:
  1. Write firmware to inactive partition
  2. Update boot configuration (U-Boot/MBR)
  3. Determine if hot reload is possible
  4. Either hot reload or reboot

  The key innovation: Even if hot reloading, we still prepare the partition
  so the device can boot into new firmware on any unexpected reboot/power loss.
  """

  require Logger

  alias NervesZeroDowntime.{
    HotReload,
    MetadataAnalyzer,
    PartitionManager,
    StateManager,
    Validator
  }

  @type update_result :: {:ok, :hot_reloaded | :rebooting} | {:error, term()}

  @doc """
  Main entry point for firmware update.

  ## Parameters
  - `firmware_path`: Path to the .fw file
  - `opts`: Options
    - `:force_reboot` - Force full reboot even if hot reload capable
    - `:dry_run` - Analyze but don't execute update
    - `:metadata` - Pre-extracted metadata (for testing)

  ## Returns
  - `{:ok, :hot_reloaded}` - Successfully hot reloaded
  - `{:ok, :rebooting}` - Reboot required, initiating reboot
  - `{:error, reason}` - Update failed
  """
  @spec apply_update(Path.t(), keyword()) :: update_result()
  def apply_update(firmware_path, opts \\ []) do
    Logger.info("Starting zero-downtime firmware update from #{firmware_path}")

    with {:ok, metadata} <- extract_or_use_metadata(firmware_path, opts),
         :ok <- Validator.pre_update_checks(),
         {:ok, update_strategy} <- determine_update_strategy(metadata, opts),
         :ok <- prepare_partition_update(firmware_path, metadata),
         {:ok, result} <- execute_update(update_strategy, firmware_path, metadata) do
      StateManager.record_update(metadata.from_version, metadata.to_version, result)
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("Firmware update failed: #{inspect(reason)}")
        handle_update_failure(reason)
        error
    end
  end

  @doc """
  Get current update status and history.
  """
  @spec status() :: map()
  def status do
    state = StateManager.read_state()

    %{
      current_version: state.current_version,
      partition_active: state.partition_active,
      last_update: state.last_successful_reload,
      pending_hot_reload: state.staged_version != nil,
      update_history: Enum.take(state.update_history, 5)
    }
  end

  @doc """
  Check if hot reload is currently available.
  """
  @spec hot_reload_available?() :: boolean()
  def hot_reload_available? do
    with {:ok, current_meta} <- get_current_metadata(),
         {:ok, staged_meta} <- get_staged_metadata() do
      case MetadataAnalyzer.analyze(current_meta, staged_meta) do
        :hot_reload_ok -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  @doc """
  Manually trigger reboot to new partition.
  """
  @spec reboot_to_new_partition() :: no_return()
  def reboot_to_new_partition do
    Logger.info("Manually triggering reboot to new partition")
    Nerves.Runtime.reboot()
  end

  @doc """
  Manually trigger rollback.
  """
  @spec rollback() :: :ok | {:error, term()}
  defdelegate rollback(), to: HotReload

  # Private functions

  defp extract_or_use_metadata(_firmware_path, opts) when is_map_key(opts, :metadata) do
    {:ok, opts[:metadata]}
  end

  defp extract_or_use_metadata(firmware_path, _opts) do
    MetadataAnalyzer.extract_from_firmware(firmware_path)
  end

  defp determine_update_strategy(metadata, opts) do
    cond do
      opts[:force_reboot] ->
        {:ok, :full_reboot}

      requires_reboot?(metadata) ->
        reason = reboot_reason(metadata)
        Logger.info("Reboot required: #{inspect(reason)}")
        {:ok, :full_reboot}

      hot_reload_safe?(metadata) ->
        Logger.info("Hot reload capable and safe")
        {:ok, :hot_reload}

      true ->
        Logger.info("Defaulting to full reboot")
        {:ok, :full_reboot}
    end
  end

  defp requires_reboot?(metadata) do
    case MetadataAnalyzer.analyze(metadata.current, metadata.new) do
      :hot_reload_ok -> false
      {:reboot_required, _reasons} -> true
    end
  end

  defp reboot_reason(metadata) do
    case MetadataAnalyzer.analyze(metadata.current, metadata.new) do
      {:reboot_required, reasons} -> reasons
      _ -> :unknown
    end
  end

  defp hot_reload_safe?(metadata) do
    # Check system conditions beyond just code compatibility
    cond do
      not enough_disk_space?() ->
        Logger.warning("Insufficient disk space for hot reload")
        false

      not system_healthy?() ->
        Logger.warning("System not healthy for hot reload")
        false

      metadata.hot_reload_capable == false ->
        Logger.info("Firmware marked as not hot-reload-capable")
        false

      true ->
        true
    end
  end

  defp enough_disk_space? do
    # Check if we have at least 100MB free on /data
    case File.stat("/data") do
      {:ok, _stat} ->
        # Simplified check - in production, use statvfs
        true

      {:error, _} ->
        false
    end
  end

  defp system_healthy? do
    # Check for system health indicators
    # - Memory pressure
    # - CPU load
    # - Error rates
    # For now, always return true
    true
  end

  defp prepare_partition_update(firmware_path, metadata) do
    Logger.info("Preparing partition update for #{metadata.to_version}")
    PartitionManager.prepare_update(firmware_path, metadata)
  end

  defp execute_update(:full_reboot, _firmware_path, _metadata) do
    Logger.info("Executing full reboot update")
    # The partition update already happened in prepare_partition_update
    # Now we just need to reboot
    spawn(fn ->
      # Give time for response to be sent
      Process.sleep(1000)
      Nerves.Runtime.reboot()
    end)

    {:ok, :rebooting}
  end

  defp execute_update(:hot_reload, firmware_path, metadata) do
    Logger.info("Executing hot reload update")

    with :ok <- HotReload.prepare(firmware_path, metadata.to_version),
         {:ok, :hot_reloaded} <- HotReload.apply(metadata.to_version),
         :ok <- Validator.post_update_validation() do
      # Mark firmware as validated
      Nerves.Runtime.validate_firmware()
      {:ok, :hot_reloaded}
    else
      {:error, reason} ->
        Logger.error("Hot reload failed: #{inspect(reason)}, falling back to reboot")
        # Hot reload failed, fall back to reboot
        spawn(fn ->
          Process.sleep(1000)
          Nerves.Runtime.reboot()
        end)
        {:ok, :rebooting}
    end
  end

  defp handle_update_failure(reason) do
    Logger.error("Update failed: #{inspect(reason)}")

    # Try to clean up any partial state
    case reason do
      {:partition_write_failed, _} ->
        # Partition write failed, may need manual intervention
        :ok

      {:hot_reload_failed, _} ->
        # Try to rollback hot reload
        HotReload.rollback()

      _ ->
        :ok
    end
  end

  defp get_current_metadata do
    # Read current firmware metadata from U-Boot env
    kv = Nerves.Runtime.KV.get_all()

    {:ok,
     %{
       version: kv["nerves_fw_version"],
       kernel_version: kv["nerves_fw_kernel_version"],
       erts_version: System.version()
     }}
  end

  defp get_staged_metadata do
    # Read staged metadata from /data/hot_reload/staged
    metadata_path = "/data/hot_reload/staged/metadata.json"

    with {:ok, content} <- File.read(metadata_path),
         {:ok, metadata} <- Jason.decode(content) do
      {:ok, metadata}
    end
  end
end

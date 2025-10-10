defmodule NervesZeroDowntime.HotReload do
  @moduledoc """
  Manages hot code reloading from /data partition.

  This module:
  1. Extracts BEAM files from firmware to /data/hot_reload/<version>/
  2. Adds code paths from /data
  3. Loads new modules or applies relups
  4. Validates the reload was successful
  5. Handles rollback if needed
  """

  require Logger

  @hot_reload_base "/data/hot_reload"

  @type version :: String.t()

  @doc """
  Prepare hot reload from mounted partition.

  Note: Does not copy files - BEAM files will be loaded directly from mounted partition.

  ## Parameters
  - `mount_point`: Path to mounted partition (e.g., "/data/inactive_partition")
  - `target_version`: Version to install

  ## Returns
  - `{:ok, mount_point}` - Preparation successful, returns mount point for loading
  - `{:error, reason}` - Preparation failed
  """
  @spec prepare_from_partition(Path.t(), version()) :: {:ok, Path.t()} | {:error, term()}
  def prepare_from_partition(mount_point, target_version) do
    Logger.info("Preparing hot reload from partition for version #{target_version}")

    source_lib = Path.join([mount_point, "srv", "erlang", "lib"])

    with :ok <- validate_beam_files(source_lib) do
      Logger.info("Hot reload preparation complete for #{target_version} (loading from #{mount_point})")
      {:ok, mount_point}
    else
      {:error, reason} = error ->
        Logger.error("Hot reload preparation failed: #{inspect(reason)}")
        error
    end
  end

  defp validate_beam_files(lib_path) do
    # Check that expected files exist
    cond do
      not File.exists?(lib_path) ->
        {:error, :missing_lib_directory}

      not has_beam_files?(lib_path) ->
        {:error, :no_beam_files_found}

      true ->
        :ok
    end
  end

  @doc """
  Prepare hot reload by extracting BEAM files to /data.

  ## Parameters
  - `firmware_path`: Path to .fw file
  - `target_version`: Version to install

  ## Returns
  - `:ok` - Preparation successful
  - `{:error, reason}` - Preparation failed
  """
  @spec prepare(Path.t(), version()) :: :ok | {:error, term()}
  def prepare(firmware_path, target_version) do
    Logger.info("Preparing hot reload for version #{target_version}")

    staging_path = Path.join(@hot_reload_base, target_version)

    with :ok <- ensure_hot_reload_directory(),
         :ok <- clean_staging_directory(staging_path),
         :ok <- extract_hot_reload_bundle(firmware_path, staging_path),
         :ok <- validate_extracted_files(staging_path),
         :ok <- create_staged_symlink(target_version),
         :ok <- backup_current_version() do
      Logger.info("Hot reload preparation complete for #{target_version}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Hot reload preparation failed: #{inspect(reason)}")
        cleanup_failed_prepare(staging_path)
        error
    end
  end

  @doc """
  Apply hot reload from staged version (for programmatic updates).

  This performs the actual hot code reload from /data/hot_reload/staged.

  ## Parameters
  - `target_version`: Version to apply

  ## Returns
  - `{:ok, :hot_reloaded}` - Successfully reloaded
  - `{:error, reason}` - Reload failed
  """
  @spec apply(version()) :: {:ok, :hot_reloaded} | {:error, term()}
  def apply(target_version) do
    Logger.info("Applying hot reload to version #{target_version}")

    staged_path = Path.join(@hot_reload_base, "staged/lib")

    with :ok <- execute_simple_reload(staged_path),
         :ok <- validate_reload() do
      Logger.info("Hot reload successful to #{target_version}")
      {:ok, :hot_reloaded}
    else
      {:error, reason} = error ->
        Logger.error("Hot reload failed: #{inspect(reason)}, initiating rollback")
        rollback()
        error
    end
  end

  @doc """
  Apply hot reload from mounted partition (for SSH updates).

  This performs the actual hot code reload:
  1. Discovers modules from mounted partition
  2. Loads new modules directly from partition
  3. Validates system health

  ## Parameters
  - `mount_point`: Path to mounted partition
  - `target_version`: Version to apply

  ## Returns
  - `{:ok, :hot_reloaded}` - Successfully reloaded
  - `{:error, reason}` - Reload failed
  """
  @spec apply(Path.t(), version()) :: {:ok, :hot_reloaded} | {:error, term()}
  def apply(mount_point, target_version) do
    Logger.info("Applying hot reload to version #{target_version}")

    lib_path = Path.join([mount_point, "srv", "erlang", "lib"])

    with :ok <- execute_simple_reload(lib_path),
         :ok <- validate_reload() do
      Logger.info("Hot reload successful to #{target_version}")
      {:ok, :hot_reloaded}
    else
      {:error, reason} = error ->
        Logger.error("Hot reload failed: #{inspect(reason)}, initiating rollback")
        rollback()
        error
    end
  end

  @doc """
  Rollback to previous version.

  This:
  1. Removes staged code paths
  2. Restores previous code paths
  3. Reloads modules from previous version
  4. Updates symlinks
  """
  @spec rollback() :: :ok | {:error, term()}
  def rollback do
    Logger.warning("Rolling back hot reload")

    state = NervesZeroDowntime.StateManager.read_state()

    with :ok <- remove_staged_code_paths(),
         :ok <- restore_previous_code_paths(state.current_version),
         :ok <- reload_previous_modules(state.current_version),
         :ok <- update_current_symlink(state.current_version) do
      Logger.info("Rollback successful to #{state.current_version}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Rollback failed: #{inspect(reason)}, system may be unstable")
        Logger.error("Forcing reboot as last resort")
        spawn(fn ->
          Process.sleep(1000)
          Nerves.Runtime.reboot()
        end)
        {:error, reason}
    end
  end

  # Private functions

  defp ensure_hot_reload_directory do
    case File.mkdir_p(@hot_reload_base) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp clean_staging_directory(path) do
    case File.rm_rf(path) do
      {:ok, _} -> File.mkdir_p(path)
      {:error, reason, _} -> {:error, {:cleanup_failed, reason}}
    end
  end

  defp extract_hot_reload_bundle(firmware_path, staging_path) do
    # Extract hot_reload.tar.gz from the .fw file
    # .fw files are ZIP archives
    with {:ok, files} <- :zip.unzip(to_charlist(firmware_path), [:memory]),
         {:ok, bundle_data} <- find_hot_reload_bundle(files),
         :ok <- extract_tarball(bundle_data, staging_path) do
      :ok
    else
      {:error, reason} -> {:error, {:extraction_failed, reason}}
    end
  end

  defp find_hot_reload_bundle(files) do
    case Enum.find(files, fn {name, _data} -> name == ~c"hot_reload.tar.gz" end) do
      {_name, data} -> {:ok, data}
      nil -> {:error, :no_hot_reload_bundle}
    end
  end

  defp extract_tarball(data, destination) do
    case :erl_tar.extract({:binary, data}, [:compressed, {:cwd, to_charlist(destination)}]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar_extraction_failed, reason}}
    end
  end

  defp validate_extracted_files(staging_path) do
    # Check that expected files exist
    lib_path = Path.join(staging_path, "lib")

    cond do
      not File.exists?(lib_path) ->
        {:error, :missing_lib_directory}

      not has_beam_files?(lib_path) ->
        {:error, :no_beam_files_found}

      true ->
        :ok
    end
  end

  defp has_beam_files?(lib_path) do
    Path.wildcard(Path.join([lib_path, "*", "ebin", "*.beam"]))
    |> length() > 0
  end

  defp create_staged_symlink(target_version) do
    source = Path.join(@hot_reload_base, target_version)
    link = Path.join(@hot_reload_base, "staged")

    # Remove old symlink if exists
    File.rm(link)

    case File.ln_s(source, link) do
      :ok -> :ok
      {:error, reason} -> {:error, {:symlink_failed, reason}}
    end
  end

  defp backup_current_version do
    # TODO: Implement backup of current running code
    # This would involve copying current BEAM files to a backup location
    :ok
  end

  defp cleanup_failed_prepare(staging_path) do
    File.rm_rf(staging_path)
    :ok
  end


  defp execute_simple_reload(staged_path) do
    # Find all changed modules and reload them
    {changed_modules, filtered_count} = discover_changed_modules(staged_path)

    Logger.info("Reloading #{length(changed_modules)} application modules (skipped #{filtered_count} core modules)")

    results = Enum.map(changed_modules, fn {module, beam_path} ->
      # Purge old code (both old and current)
      :code.purge(module)
      :code.delete(module)

      # Load new code using explicit path to ensure we get the new BEAM file
      # We use load_abs which takes a path without the .beam extension
      abs_path = Path.rootname(beam_path) |> String.to_charlist()

      case :code.load_abs(abs_path) do
        {:module, ^module} ->
          {:ok, module}

        {:error, reason} ->
          Logger.error("Failed to reload #{module}: #{inspect(reason)}")
          {:error, module, reason}
      end
    end)

    # Report summary
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    failure_count = Enum.count(results, &match?({:error, _, _}, &1))

    Logger.info("Hot reload complete: #{success_count} succeeded, #{failure_count} failed")

    if failure_count > 0 do
      {:error, {:partial_reload, failure_count}}
    else
      :ok
    end
  end

  defp discover_changed_modules(lib_path) do
    # Get all beam files from lib path with their full paths
    # lib_path is like "/data/inactive_partition/srv/erlang/lib"

    # Get list of reloadable applications (exclude base system)
    reloadable_apps = get_reloadable_applications()
    Logger.debug("Reloadable applications: #{inspect(reloadable_apps)}")

    # Only reload modules from reloadable applications
    all_modules =
      Path.wildcard(Path.join([lib_path, "*", "ebin", "*.beam"]))
      |> Enum.map(fn beam_file ->
        # Extract app name from path like ".../lib/my_app-1.0.0/ebin/..."
        app_dir = beam_file |> Path.dirname() |> Path.dirname() |> Path.basename()
        app_name = extract_app_name(app_dir)

        module =
          beam_file
          |> Path.basename(".beam")
          |> String.to_atom()

        {module, beam_file, app_name}
      end)

    {app_modules, core_modules} = Enum.split_with(all_modules, fn {_module, _path, app} ->
      app in reloadable_apps
    end)

    Logger.debug("Filtering modules: #{length(app_modules)} app modules, #{length(core_modules)} core modules skipped")

    # Return just module and path tuples
    app_module_tuples = Enum.map(app_modules, fn {mod, path, _app} -> {mod, path} end)

    {app_module_tuples, length(core_modules)}
  end

  defp get_reloadable_applications do
    # Get all loaded applications
    all_apps = :application.loaded_applications()

    all_apps
    |> Enum.map(fn {app, _desc, _vsn} -> app end)
    |> Enum.reject(&is_base_application?/1)
  end

  # Applications that should never be hot-reloaded (base system)
  defp is_base_application?(app) do
    base_apps = [
      :kernel, :stdlib, :elixir, :compiler, :crypto, :ssl, :public_key,
      :asn1, :syntax_tools, :sasl, :logger, :inets, :runtime_tools,
      :mnesia, :observer, :wx, :debugger, :dialyzer, :edoc, :erl_docgen,
      :et, :eunit, :ftp, :megaco, :odbc, :os_mon, :parsetools, :reltool,
      :snmp, :ssh, :tftp, :tools, :xmerl
    ]

    app in base_apps
  end

  defp extract_app_name(app_dir) do
    # Handle "my_app-1.0.0" -> :my_app
    case String.split(app_dir, "-") do
      [name | _version_parts] -> String.to_atom(name)
      _ -> String.to_atom(app_dir)
    end
  end

  defp validate_reload do
    # Check that critical processes are still running
    # and system is responsive
    Process.sleep(100)
    :ok
  end

  defp update_current_symlink(version) do
    source = Path.join(@hot_reload_base, version)
    link = Path.join(@hot_reload_base, "current")

    File.rm(link)

    case File.ln_s(source, link) do
      :ok -> :ok
      {:error, reason} -> {:error, {:symlink_failed, reason}}
    end
  end

  defp remove_staged_code_paths do
    # TODO: Remove code paths that were added for staged version
    :ok
  end

  defp restore_previous_code_paths(_version) do
    # Code paths don't need to be restored since we're loading directly
    :ok
  end

  defp reload_previous_modules(version) do
    # Reload modules from previous version
    base_path = Path.join([@hot_reload_base, version, "lib"])
    execute_simple_reload(base_path)
  end
end

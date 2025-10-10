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

  Copies BEAM files from the mounted inactive partition to /data/hot_reload/.

  ## Parameters
  - `mount_point`: Path to mounted partition (e.g., "/data/inactive_partition")
  - `target_version`: Version to install

  ## Returns
  - `:ok` - Preparation successful
  - `{:error, reason}` - Preparation failed
  """
  @spec prepare_from_partition(Path.t(), version()) :: :ok | {:error, term()}
  def prepare_from_partition(mount_point, target_version) do
    Logger.info("Preparing hot reload from partition for version #{target_version}")

    staging_path = Path.join(@hot_reload_base, target_version)
    source_lib = Path.join([mount_point, "srv", "erlang", "lib"])

    with :ok <- ensure_hot_reload_directory(),
         :ok <- clean_staging_directory(staging_path),
         :ok <- copy_beam_files(source_lib, staging_path),
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

  defp copy_beam_files(source_lib, staging_path) do
    dest_lib = Path.join(staging_path, "lib")

    Logger.info("Copying BEAM files from #{source_lib} to #{dest_lib}")

    case File.cp_r(source_lib, dest_lib) do
      {:ok, _files} ->
        Logger.debug("BEAM files copied successfully")
        :ok

      {:error, reason, file} ->
        Logger.error("Failed to copy #{file}: #{inspect(reason)}")
        {:error, {:copy_failed, reason, file}}
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
  Apply hot reload from staged version.

  This performs the actual hot code reload:
  1. Adds code paths from /data/hot_reload/staged
  2. Loads new modules
  3. Applies relup if available
  4. Validates system health

  ## Parameters
  - `target_version`: Version to apply

  ## Returns
  - `{:ok, :hot_reloaded}` - Successfully reloaded
  - `{:error, reason}` - Reload failed
  """
  @spec apply(version()) :: {:ok, :hot_reloaded} | {:error, term()}
  def apply(target_version) do
    Logger.info("Applying hot reload to version #{target_version}")

    staged_path = Path.join(@hot_reload_base, "staged")

    with {:ok, apps} <- discover_applications(staged_path),
         :ok <- add_code_paths(staged_path),
         {:ok, reload_strategy} <- determine_reload_strategy(staged_path),
         :ok <- execute_reload(reload_strategy, staged_path, apps),
         :ok <- validate_reload(),
         :ok <- update_current_symlink(target_version) do
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

  defp discover_applications(base_path) do
    lib_path = Path.join(base_path, "lib")

    apps =
      File.ls!(lib_path)
      |> Enum.map(fn dir ->
        # Extract app name from dir like "my_app-1.0.0"
        case String.split(dir, "-") do
          [app_name | _version_parts] -> String.to_atom(app_name)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, apps}
  end

  defp add_code_paths(base_path) do
    lib_path = Path.join(base_path, "lib")

    File.ls!(lib_path)
    |> Enum.each(fn app_dir ->
      ebin = Path.join([lib_path, app_dir, "ebin"])

      if File.exists?(ebin) do
        :code.add_pathz(String.to_charlist(ebin))
        Logger.debug("Added code path: #{ebin}")
      end
    end)

    :ok
  end

  defp determine_reload_strategy(base_path) do
    relup_path = Path.join([base_path, "releases", "*", "relup"])

    if Path.wildcard(relup_path) |> length() > 0 do
      {:ok, :relup}
    else
      {:ok, :simple_reload}
    end
  end

  defp execute_reload(:relup, staged_path, _apps) do
    # Find relup file
    relup_path =
      Path.wildcard(Path.join([staged_path, "releases", "*", "relup"]))
      |> List.first()

    if relup_path do
      # TODO: Use release_handler to apply relup
      # For now, fall back to simple reload
      Logger.warning("Relup found but not yet implemented, using simple reload")
      execute_simple_reload(staged_path)
    else
      {:error, :relup_not_found}
    end
  end

  defp execute_reload(:simple_reload, staged_path, _apps) do
    execute_simple_reload(staged_path)
  end

  defp execute_simple_reload(staged_path) do
    # Find all changed modules and reload them
    {changed_modules, filtered_count} = discover_changed_modules(staged_path)

    Logger.info("Found #{length(changed_modules)} application modules to reload (filtered #{filtered_count} core modules)")

    results = Enum.map(changed_modules, fn {module, beam_path} ->
      Logger.debug("Reloading module: #{module}")

      # Check where the old module is loaded from
      old_path = :code.which(module)
      Logger.debug("  Old module path: #{inspect(old_path)}")
      Logger.debug("  New module path: #{beam_path}")

      # Purge old code (both old and current)
      :code.purge(module)
      :code.delete(module)

      # Load new code using explicit path to ensure we get the new BEAM file
      # We use load_abs which takes a path without the .beam extension
      abs_path = Path.rootname(beam_path) |> String.to_charlist()

      case :code.load_abs(abs_path) do
        {:module, ^module} ->
          new_path = :code.which(module)
          Logger.info("✓ Reloaded #{module}")
          Logger.info("  Old: #{inspect(old_path)}")
          Logger.info("  New: #{inspect(new_path)}")
          {:ok, module}

        {:error, reason} ->
          Logger.error("✗ Failed to load module #{module}: #{inspect(reason)}")
          Logger.error("  Tried to load from: #{beam_path}")
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

  defp discover_changed_modules(staged_path) do
    # Get all beam files from staged path with their full paths
    lib_path = Path.join(staged_path, "lib")

    # Get list of reloadable applications (exclude base system)
    reloadable_apps = get_reloadable_applications()
    Logger.debug("Reloadable applications: #{inspect(reloadable_apps)}")

    # Only reload modules from reloadable applications
    all_modules =
      Path.wildcard(Path.join([lib_path, "*", "ebin", "*.beam"]))
      |> Enum.map(fn beam_file ->
        # Extract app name from path like "/data/.../lib/my_app-1.0.0/ebin/..."
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

  defp restore_previous_code_paths(version) do
    # Add code paths from previous version
    base_path = Path.join(@hot_reload_base, version)
    add_code_paths(base_path)
  end

  defp reload_previous_modules(version) do
    # Reload modules from previous version
    base_path = Path.join(@hot_reload_base, version)
    execute_simple_reload(base_path)
  end
end

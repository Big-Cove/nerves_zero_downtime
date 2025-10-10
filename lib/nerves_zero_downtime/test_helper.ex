defmodule NervesZeroDowntime.TestHelper do
  @moduledoc """
  Helper functions for testing hot reload functionality without full firmware builds.

  These functions allow you to create test hot reload bundles and simulate
  the firmware update process for testing.
  """

  require Logger

  @doc """
  Create a fake hot reload bundle from the current application.

  This is useful for testing without building a full firmware image.

  ## Example

      NervesZeroDowntime.TestHelper.create_test_bundle("0.1.8")
  """
  def create_test_bundle(version) do
    Logger.info("Creating test hot reload bundle for version #{version}")

    bundle_path = "/data/staged_hot_reload.tar.gz"
    staging_dir = "/tmp/hot_reload_staging"

    # Create staging directory
    File.rm_rf!(staging_dir)
    File.mkdir_p!(staging_dir)

    # Copy current app BEAM files
    app_name = Mix.Project.config()[:app]
    source_lib = Path.join([:code.lib_dir(app_name), "ebin"])

    if File.exists?(source_lib) do
      dest_lib = Path.join([staging_dir, "lib", "#{app_name}-#{version}", "ebin"])
      File.mkdir_p!(dest_lib)
      File.cp_r!(source_lib, dest_lib)

      # Create tarball
      {:ok, tar} = :erl_tar.open(to_charlist(bundle_path), [:write, :compressed])
      add_directory_to_tar(tar, staging_dir, "")
      :erl_tar.close(tar)

      # Cleanup
      File.rm_rf!(staging_dir)

      Logger.info("Test bundle created at #{bundle_path}")
      :ok
    else
      {:error, :source_not_found}
    end
  end

  @doc """
  Simulate testing without actually mounting partitions.

  Note: Full integration testing requires a real Nerves device with
  inactive partition that can be mounted. This function is mainly
  for documentation purposes.
  """
  def test_note do
    Logger.info("""
    To test hot reload:

    1. Build firmware with a version bump
    2. Upload via: mix upload <ip>
    3. Watch logs on device for hot reload messages
    4. If the partition can't be mounted, the system will reboot

    The system automatically reads from the inactive partition - no
    manual staging needed!
    """)

    :ok
  end

  @doc """
  Simulate an SSH firmware update callback for testing.

  This is equivalent to what happens after a real firmware upload.
  """
  def simulate_ssh_callback do
    Logger.info("Simulating SSH firmware update callback")
    spawn(fn ->
      case NervesZeroDowntime.determine_and_apply_staged_update() do
        {:ok, :hot_reloaded} ->
          Logger.info("✓ Hot reload succeeded")

        {:ok, :rebooting} ->
          Logger.info("→ Would reboot now (skipped in test)")

        {:error, reason} ->
          Logger.error("✗ Update failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Private helpers

  defp add_directory_to_tar(tar, dir, prefix) do
    File.ls!(dir)
    |> Enum.each(fn entry ->
      source_path = Path.join(dir, entry)
      tar_path = if prefix == "", do: entry, else: Path.join(prefix, entry)

      if File.dir?(source_path) do
        add_directory_to_tar(tar, source_path, tar_path)
      else
        :erl_tar.add(tar, to_charlist(source_path), to_charlist(tar_path), [])
      end
    end)
  end
end

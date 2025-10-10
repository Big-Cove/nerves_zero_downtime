defmodule NervesZeroDowntime.MetadataAnalyzer do
  @moduledoc """
  Analyzes firmware metadata to determine if hot reload is possible
  or if a full reboot is required.

  This module compares old and new firmware metadata to detect changes
  that would require a reboot:
  - Kernel version changes
  - Device tree changes
  - ERTS version changes
  - NIF library changes
  - Core OTP app changes
  """

  require Logger

  @type metadata :: map()
  @type analysis_result :: :hot_reload_ok | {:reboot_required, [atom()]}

  @doc """
  Analyze firmware metadata and determine if hot reload is safe.

  Returns `:hot_reload_ok` if the update can be hot-reloaded,
  or `{:reboot_required, reasons}` with a list of reasons why reboot is needed.
  """
  @spec analyze(metadata(), metadata()) :: analysis_result()
  def analyze(old_metadata, new_metadata) do
    reasons = []

    reasons = check_kernel(old_metadata, new_metadata, reasons)
    reasons = check_device_tree(old_metadata, new_metadata, reasons)
    reasons = check_erts(old_metadata, new_metadata, reasons)
    reasons = check_nifs(old_metadata, new_metadata, reasons)
    reasons = check_boot_config(old_metadata, new_metadata, reasons)
    reasons = check_core_apps(old_metadata, new_metadata, reasons)

    case reasons do
      [] -> :hot_reload_ok
      list -> {:reboot_required, list}
    end
  end

  @doc """
  Extract metadata from a .fw firmware file.
  """
  @spec extract_from_firmware(Path.t()) :: {:ok, map()} | {:error, term()}
  def extract_from_firmware(firmware_path) do
    with {:ok, files} <- :zip.unzip(to_charlist(firmware_path), [:memory]),
         {:ok, meta_data} <- find_file(files, "meta.conf"),
         {:ok, metadata} <- parse_metadata(meta_data) do
      # Get current system metadata
      current_metadata = get_current_metadata()

      {:ok,
       %{
         current: current_metadata,
         new: metadata,
         from_version: current_metadata[:version],
         to_version: metadata[:version],
         hot_reload_capable: metadata[:hot_reload_capable] || false
       }}
    else
      {:error, reason} -> {:error, {:metadata_extraction_failed, reason}}
    end
  end

  # Private functions

  defp check_kernel(old_meta, new_meta, reasons) do
    old_kernel = Map.get(old_meta, :kernel_version)
    new_kernel = Map.get(new_meta, :kernel_version)

    if old_kernel != new_kernel and not is_nil(old_kernel) and not is_nil(new_kernel) do
      Logger.info("Kernel version changed: #{old_kernel} -> #{new_kernel}")
      [:kernel_version_changed | reasons]
    else
      reasons
    end
  end

  defp check_device_tree(old_meta, new_meta, reasons) do
    old_dtb = Map.get(old_meta, :dtb_hash)
    new_dtb = Map.get(new_meta, :dtb_hash)

    if old_dtb != new_dtb and not is_nil(old_dtb) and not is_nil(new_dtb) do
      Logger.info("Device tree changed")
      [:device_tree_changed | reasons]
    else
      reasons
    end
  end

  defp check_erts(old_meta, new_meta, reasons) do
    old_erts = Map.get(old_meta, :erts_version)
    new_erts = Map.get(new_meta, :erts_version)

    if old_erts != new_erts and not is_nil(old_erts) and not is_nil(new_erts) do
      Logger.info("ERTS version changed: #{old_erts} -> #{new_erts}")
      [:erts_version_changed | reasons]
    else
      reasons
    end
  end

  defp check_nifs(old_meta, new_meta, reasons) do
    old_nifs = MapSet.new(Map.get(old_meta, :nif_libraries, []))
    new_nifs = MapSet.new(Map.get(new_meta, :nif_libraries, []))

    if MapSet.equal?(old_nifs, new_nifs) do
      reasons
    else
      added = MapSet.difference(new_nifs, old_nifs) |> MapSet.to_list()
      removed = MapSet.difference(old_nifs, new_nifs) |> MapSet.to_list()

      Logger.info("NIF libraries changed - Added: #{inspect(added)}, Removed: #{inspect(removed)}")
      [:nif_changes | reasons]
    end
  end

  defp check_boot_config(old_meta, new_meta, reasons) do
    old_hash = Map.get(old_meta, :boot_config_hash)
    new_hash = Map.get(new_meta, :boot_config_hash)

    if old_hash != new_hash and not is_nil(old_hash) and not is_nil(new_hash) do
      Logger.info("Boot configuration changed")
      [:boot_config_changed | reasons]
    else
      reasons
    end
  end

  defp check_core_apps(old_meta, new_meta, reasons) do
    core_apps = [:kernel, :stdlib, :sasl, :compiler]

    old_versions = Map.get(old_meta, :app_versions, %{})
    new_versions = Map.get(new_meta, :app_versions, %{})

    changed =
      Enum.any?(core_apps, fn app ->
        old_versions[app] != new_versions[app]
      end)

    if changed do
      Logger.info("Core OTP application versions changed")
      [:core_app_changed | reasons]
    else
      reasons
    end
  end

  defp find_file(files, filename) do
    case Enum.find(files, fn {name, _data} -> to_string(name) == filename end) do
      {_name, data} -> {:ok, data}
      nil -> {:error, {:file_not_found, filename}}
    end
  end

  defp parse_metadata(data) do
    # Parse meta.conf format (key=value pairs)
    lines = String.split(data, "\n", trim: true)

    metadata =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key_atom = parse_key(key)
            Map.put(acc, key_atom, String.trim(value, "\""))

          _ ->
            acc
        end
      end)

    {:ok, metadata}
  end

  defp parse_key("meta-version"), do: :version
  defp parse_key("meta-platform"), do: :platform
  defp parse_key("meta-architecture"), do: :architecture
  defp parse_key("meta-author"), do: :author
  defp parse_key("meta-product"), do: :product
  defp parse_key("meta-description"), do: :description
  defp parse_key("meta-kernel-version"), do: :kernel_version
  defp parse_key("meta-erts-version"), do: :erts_version
  defp parse_key("meta-hot-reload-capable"), do: :hot_reload_capable
  defp parse_key("meta-requires-reboot"), do: :requires_reboot
  defp parse_key(key), do: String.to_atom(key)

  defp get_current_metadata do
    # Get metadata about currently running firmware
    kv = Nerves.Runtime.KV.get_all()

    %{
      version: kv["nerves_fw_version"],
      platform: kv["nerves_fw_platform"],
      architecture: kv["nerves_fw_architecture"],
      kernel_version: get_kernel_version(),
      erts_version: System.version(),
      app_versions: get_application_versions()
    }
  end

  defp get_kernel_version do
    case File.read("/proc/version") do
      {:ok, content} ->
        # Extract version from "Linux version X.Y.Z ..."
        case Regex.run(~r/Linux version ([\d\.]+)/, content) do
          [_, version] -> version
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp get_application_versions do
    Application.loaded_applications()
    |> Enum.map(fn {app, _desc, version} ->
      {app, to_string(version)}
    end)
    |> Map.new()
  end
end

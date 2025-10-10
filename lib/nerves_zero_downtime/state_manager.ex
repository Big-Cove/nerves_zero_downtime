defmodule NervesZeroDowntime.StateManager do
  @moduledoc """
  Manages persistent state for zero-downtime updates.

  Tracks:
  - Current version
  - Staged version (if any)
  - Update history
  - Partition information
  """

  require Logger

  @state_file "/data/zero_downtime_state.etf"

  defstruct [
    :current_version,
    :staged_version,
    :partition_active,
    :partition_staged,
    :last_successful_reload,
    :rollback_available,
    update_history: []
  ]

  @type t :: %__MODULE__{
          current_version: String.t() | nil,
          staged_version: String.t() | nil,
          partition_active: String.t() | nil,
          partition_staged: String.t() | nil,
          last_successful_reload: integer() | nil,
          rollback_available: boolean(),
          update_history: [map()]
        }

  @doc """
  Read state from persistent storage.
  """
  @spec read_state() :: t()
  def read_state do
    case File.read(@state_file) do
      {:ok, binary} ->
        :erlang.binary_to_term(binary)

      {:error, :enoent} ->
        # Initialize with current system state
        %__MODULE__{
          current_version: get_current_version(),
          partition_active: get_active_partition(),
          rollback_available: false
        }

      {:error, reason} ->
        Logger.warning("Failed to read state file: #{inspect(reason)}, using defaults")

        %__MODULE__{
          current_version: get_current_version(),
          partition_active: get_active_partition(),
          rollback_available: false
        }
    end
  end

  @doc """
  Write state to persistent storage.
  """
  @spec write_state(t()) :: :ok | {:error, term()}
  def write_state(state) do
    binary = :erlang.term_to_binary(state)

    case File.write(@state_file, binary) do
      :ok -> :ok
      {:error, reason} -> {:error, {:state_write_failed, reason}}
    end
  end

  @doc """
  Record an update in the history.
  """
  @spec record_update(String.t(), String.t(), atom()) :: :ok
  def record_update(from_version, to_version, result) do
    state = read_state()

    entry = %{
      timestamp: System.system_time(:second),
      from_version: from_version,
      to_version: to_version,
      result: result
    }

    updated_state = %{
      state
      | current_version: to_version,
        staged_version: nil,
        last_successful_reload:
          if(result == :hot_reloaded, do: System.system_time(:second), else: state.last_successful_reload),
        update_history: [entry | state.update_history] |> Enum.take(10)
    }

    write_state(updated_state)
  end

  # Private functions

  defp get_current_version do
    Nerves.Runtime.KV.get("nerves_fw_version")
  end

  defp get_active_partition do
    Nerves.Runtime.KV.get("nerves_fw_active")
  end
end

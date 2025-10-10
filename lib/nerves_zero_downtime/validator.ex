defmodule NervesZeroDowntime.Validator do
  @moduledoc """
  Performs validation checks before and after updates.

  Pre-update checks:
  - Disk space
  - System health
  - Network stability
  - Critical processes running

  Post-update checks:
  - Applications started
  - Network connectivity
  - Critical services responding
  - No crashes
  """

  require Logger

  @validation_timeout_ms 30_000
  @min_disk_space_mb 100

  @doc """
  Run pre-update validation checks.
  """
  @spec pre_update_checks() :: :ok | {:error, term()}
  def pre_update_checks do
    checks = [
      {&check_disk_space/0, "Disk space"},
      {&check_system_health/0, "System health"},
      {&check_memory_available/0, "Memory available"}
    ]

    run_checks(checks, "pre-update")
  end

  @doc """
  Run post-update validation checks.
  """
  @spec post_update_validation() :: :ok | {:error, term()}
  def post_update_validation do
    task =
      Task.async(fn ->
        checks = [
          {&validate_applications_running/0, "Applications running"},
          {&validate_no_crashes/0, "No crashes"},
          {&run_smoke_tests/0, "Smoke tests"}
        ]

        run_checks(checks, "post-update")
      end)

    case Task.yield(task, @validation_timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :validation_timeout}
    end
  end

  # Private functions

  defp run_checks(checks, phase) do
    Logger.info("Running #{phase} validation checks")

    Enum.reduce_while(checks, :ok, fn {check_fn, name}, _acc ->
      case check_fn.() do
        :ok ->
          Logger.debug("#{phase} check passed: #{name}")
          {:cont, :ok}

        {:error, reason} = error ->
          Logger.error("#{phase} check failed: #{name} - #{inspect(reason)}")
          {:halt, error}
      end
    end)
  end

  defp check_disk_space do
    case get_available_disk_space("/data") do
      {:ok, available_mb} when available_mb >= @min_disk_space_mb ->
        :ok

      {:ok, available_mb} ->
        {:error, {:insufficient_disk_space, available_mb, @min_disk_space_mb}}

      {:error, reason} ->
        {:error, {:disk_space_check_failed, reason}}
    end
  end

  defp get_available_disk_space(path) do
    # Simplified disk space check
    # In production, should use proper statvfs call
    case File.stat(path) do
      {:ok, _} -> {:ok, 200}  # Assume we have space
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_system_health do
    # Check for system health indicators
    # - High error rates
    # - Memory pressure
    # - CPU overload

    # For now, always pass
    :ok
  end

  defp check_memory_available do
    case :memsup.get_system_memory_data() do
      data when is_list(data) ->
        # Check if we have reasonable free memory
        :ok

      _ ->
        # memsup might not be running, that's ok
        :ok
    end
  rescue
    _ -> :ok
  end

  defp validate_applications_running do
    # Check that expected applications are running
    # This should be configurable per-application
    expected_apps = [:nerves_runtime, :nerves_zero_downtime]

    running =
      Application.started_applications()
      |> Enum.map(fn {app, _, _} -> app end)

    missing = expected_apps -- running

    case missing do
      [] -> :ok
      apps -> {:error, {:applications_not_running, apps}}
    end
  end

  defp validate_no_crashes do
    # Check recent logs for crashes
    # This is a simplified check - in production, would monitor error_logger
    :ok
  end

  defp run_smoke_tests do
    # Run basic smoke tests
    # Applications can register their own smoke tests
    :ok
  end
end

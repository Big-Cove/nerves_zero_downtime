defmodule NervesZeroDowntime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias NervesZeroDowntime.BootedPartition

  @impl true
  def start(_type, _args) do
    # Initialize nerves_fw_booted at startup (idempotent - only sets if not already set)
    BootedPartition.initialize_booted_partition()

    children = [
      # Starts a worker by calling: NervesZeroDowntime.Worker.start_link(arg)
      # {NervesZeroDowntime.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NervesZeroDowntime.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

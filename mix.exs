defmodule NervesZeroDowntime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nerves-project/nerves_zero_downtime"

  def project do
    [
      app: :nerves_zero_downtime,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      preferred_cli_env: [
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {NervesZeroDowntime.Application, []}
    ]
  end

  defp deps do
    [
      # Optional - needed only if using uboot_env directly
      {:uboot_env, "~> 1.0", optional: true},
      # JSON parsing for metadata
      {:jason, "~> 1.4"},
      # Documentation
      {:ex_doc, "~> 0.31", only: :docs, runtime: false}
    ]
  end

  defp description do
    """
    Zero-downtime firmware updates for Nerves devices by combining
    A/B partition safety with BEAM hot code reloading.
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "IMPLEMENTATION.md": [title: "Implementation Guide"]
      ]
    ]
  end
end

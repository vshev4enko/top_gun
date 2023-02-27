defmodule TopGun.MixProject do
  use Mix.Project

  def project do
    [
      app: :top_gun,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cowlib, "~> 2.12", override: true},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:gun, "~> 2.0"},
      {:jason, "~> 1.4", only: [:test]},
      {:plug_cowboy, "~> 2.6", only: [:test]}
    ]
  end
end

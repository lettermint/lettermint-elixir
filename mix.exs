defmodule Lettermint.MixProject do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      app: :lettermint,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:req, "~> 0.7.4"},
        {:jason, "~> 1.4"},
        {:ex_doc, "~> 0.39", only: :dev, runtime: false}
      ],
      name: "Lettermint",
      source_url: "https://github.com/lettermint/lettermint-elixir",
      homepage_url: "https://lettermint.co",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"],
      description: "Elixir SDK for the Lettermint sending and team APIs.",
      package: [
        licenses: ["MIT"],
        links: %{
          "Lettermint" => "https://lettermint.co",
          "GitHub" => "https://github.com/lettermint/lettermint-elixir"
        },
        files: ["lib", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end

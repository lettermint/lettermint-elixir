defmodule Lettermint.MixProject do
  use Mix.Project

  # The release workflow sets the published version from the git tag
  # (.github/scripts/set-release-version.sh); this value is for development.
  @version "2.0.0-dev"
  @source_url "https://github.com/lettermint/lettermint-elixir"

  def project do
    [
      app: :lettermint,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Lettermint",
      source_url: @source_url,
      homepage_url: "https://lettermint.co",
      docs: docs(),
      description: "Elixir SDK for the Lettermint sending and team APIs.",
      package: [
        licenses: ["MIT"],
        links: %{
          "Lettermint" => "https://lettermint.co",
          "GitHub" => @source_url
        },
        files: ["lib", "mix.exs", "README.md", "UPGRADE.md", "LICENSE", "CHANGELOG.md"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:mint, "~> 1.11.0"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "UPGRADE.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Client: [Lettermint, Lettermint.Client, Lettermint.Adapter, Lettermint.Adapter.Req],
        Sending: [Lettermint.Emails, Lettermint.EmailBuilder],
        "Team API": [
          Lettermint.Domains,
          Lettermint.Messages,
          Lettermint.Projects,
          Lettermint.Projects.ReportForwarding,
          Lettermint.Routes,
          Lettermint.Stats,
          Lettermint.Suppressions,
          Lettermint.Team,
          Lettermint.Team.Members,
          Lettermint.Webhooks,
          Lettermint.Webhooks.Deliveries
        ],
        Webhooks: [Lettermint.Webhook, Lettermint.WebhookPayload],
        Errors: [
          Lettermint.Error,
          Lettermint.APIError,
          Lettermint.AuthenticationError,
          Lettermint.PermissionError,
          Lettermint.NotFoundError,
          Lettermint.ConflictError,
          Lettermint.ValidationError,
          Lettermint.RateLimitError,
          Lettermint.ServerError,
          Lettermint.TimeoutError,
          Lettermint.ConnectionError,
          Lettermint.UnexpectedResponseError,
          Lettermint.RedirectError,
          Lettermint.ConfigError,
          Lettermint.ClientValidationError,
          Lettermint.WebhookVerificationError
        ],
        "Requests and queries": [Lettermint.Query, Lettermint.Operations],
        Types: ~r/^Lettermint\.Types/
      ]
    ]
  end
end

defmodule Lettermint do
  @moduledoc """
  The Lettermint client.

      lettermint =
        Lettermint.new(
          sending_token: System.get_env("LETTERMINT_PROJECT_TOKEN"),
          team_token: System.get_env("LETTERMINT_TEAM_TOKEN")
        )

      lettermint = Lettermint.new("lm_...")  # team or sending token, detected by its format

  Pass the client as the first argument to the SDK's functions:

    * `Lettermint.Emails` and `Lettermint.EmailBuilder` send email with the
      sending token (`x-lettermint-token`);
    * every other module uses the team token (`Authorization: Bearer`):
      `Lettermint.Domains`, `Lettermint.Messages`, `Lettermint.Projects`,
      `Lettermint.Projects.ReportForwarding`, `Lettermint.Routes`,
      `Lettermint.Stats`, `Lettermint.Suppressions`, `Lettermint.Team`,
      `Lettermint.Team.Members`, `Lettermint.Webhooks`,
      `Lettermint.Webhooks.Deliveries`, and `analytics/3` and
      `blocked_file_types/2` below;
    * `ping/2`, `Lettermint.Messages.reschedule/4` and
      `Lettermint.Messages.cancel/3` use the team token when it is set,
      otherwise the sending token.

  The SDK never falls back to the other token. When the token a function
  needs is missing, it raises `Lettermint.ConfigError` before any request.

  Functions that call the API return `{:ok, result}` (or `:ok` when the API
  answers without a body) or `{:error, error}`; see `Lettermint.Error`.
  """

  alias Lettermint.{Client, Transport, Types}

  @doc """
  Creates a client from options or from a token string.

  ## Options

    * `:sending_token`: a project sending token (`lm_...`), for `Lettermint.Emails`
    * `:team_token`: a team API token (`lm_team_...`), for the Team API
    * `:base_url`: default `"https://api.lettermint.co/v1"`
    * `:timeout`: milliseconds, default `30_000`. It covers the whole request,
      including reading the body. Each call can override it with `timeout:`.
    * `:adapter`: the HTTP adapter, a module or `{module, options}`; default
      `Lettermint.Adapter.Req`. See `Lettermint.Adapter`.

  Pass at least one token. With a token string, the SDK picks the token type
  by its format: `lm_team_` followed by letters and digits is a team token,
  `lm_` followed by letters and digits a sending token. Any other format, such
  as an SSO token (`lm_sso_...`), raises `Lettermint.ConfigError`; pass it
  with `:sending_token` or `:team_token` instead. Errors never contain the
  token.

      Lettermint.new(sending_token: token)
      Lettermint.new(token, timeout: 10_000)
  """
  @spec new(String.t() | keyword()) :: Client.t()
  def new(token_or_options), do: Client.new(token_or_options)

  @doc "Creates a client from a token string and options. See `new/1`."
  @spec new(String.t(), keyword()) :: Client.t()
  def new(token, options), do: Client.new(token, options)

  @doc """
  Checks the configured token: `GET /ping` returns `"pong"`. Uses the team
  token when configured, otherwise the sending token.
  """
  @spec ping(Client.t(), timeout: pos_integer()) ::
          {:ok, String.t()} | {:error, Lettermint.Error.t()}
  def ping(%Client{} = client, options \\ []) do
    with {:ok, text} <- Transport.call(client, "GET /ping", %{label: "ping", options: options}) do
      {:ok, String.trim(text)}
    end
  end

  @doc "Queries email analytics. Needs `:team_token`."
  @spec analytics(Client.t(), Types.AnalyticsQuery.t() | map(), timeout: pos_integer()) ::
          {:ok, Types.AnalyticsResponse.t()} | {:error, Lettermint.Error.t()}
  def analytics(%Client{} = client, query, options \\ []) do
    Transport.call(client, "POST /analytics", %{label: "analytics", body: query, options: options})
  end

  @doc "The file extensions and MIME types that cannot be attached. Needs `:team_token`."
  @spec blocked_file_types(Client.t(), timeout: pos_integer()) ::
          {:ok, Types.BlockedFileTypes.t()} | {:error, Lettermint.Error.t()}
  def blocked_file_types(%Client{} = client, options \\ []) do
    Transport.call(client, "GET /blocked-file-types", %{
      label: "blocked_file_types",
      options: options
    })
  end
end

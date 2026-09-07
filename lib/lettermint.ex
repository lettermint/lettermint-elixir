defmodule Lettermint do
  @moduledoc "Clients for the Lettermint sending and team APIs."
  @doc "Create a client with a project token."
  def email(token, opts \\ []), do: Lettermint.Client.new(:sending, token, opts)
  @doc "Create a client with a team token."
  def api(token, opts \\ []), do: Lettermint.Client.new(:team, token, opts)
end

defmodule Lettermint.Client do
  @moduledoc "An immutable API client. Create it with `Lettermint.email/2` or `Lettermint.api/2`."
  @derive {Inspect, only: [:surface, :base_url, :timeout]}
  @enforce_keys [:surface, :token]
  defstruct [
    :surface,
    :token,
    base_url: "https://api.lettermint.co/v1",
    timeout: 30_000,
    adapter: Lettermint.HTTP
  ]

  @type t :: %__MODULE__{
          surface: :sending | :team,
          token: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          adapter: module()
        }

  @doc false
  def new(surface, token, opts) when is_binary(token) and byte_size(token) > 0 do
    unless String.trim(token) == token and not String.contains?(token, ["\r", "\n"]) do
      raise ArgumentError, "Invalid API token"
    end

    unknown = Keyword.keys(opts) -- [:base_url, :timeout, :adapter]
    if unknown != [], do: raise(ArgumentError, "Unknown client option")
    client = struct!(__MODULE__, [surface: surface, token: token] ++ opts)
    uri = URI.parse(client.base_url)

    unless uri.scheme in ["http", "https"] and uri.host not in [nil, ""] and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      raise ArgumentError, "Invalid API base URL"
    end

    unless is_integer(client.timeout) and client.timeout > 0,
      do: raise(ArgumentError, "Invalid timeout")

    %{client | base_url: String.trim_trailing(client.base_url, "/")}
  end

  def new(_, _, _), do: raise(ArgumentError, "An API token is required")
end

defmodule Lettermint.Error do
  @moduledoc "An API, transport, or response error. API response data is available in `body`."
  defexception [:kind, :status, :body, message: "Lettermint request failed"]
  @type t :: %__MODULE__{kind: atom(), status: integer() | nil, body: term(), message: String.t()}
end

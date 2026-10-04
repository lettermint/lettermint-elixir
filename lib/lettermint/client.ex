defmodule Lettermint.Client do
  @moduledoc """
  The client configuration: tokens, base URL, timeout and HTTP adapter.

  Create it with `Lettermint.new/1` or `Lettermint.new/2` and pass it as the
  first argument to every SDK function. The struct is immutable, holds no
  message state and is safe to share between processes; create it once.

  The tokens are kept inside closures, so they appear in no debug output:
  `inspect/2` (also with `structs: false`), `:io_lib.format("~p", ...)`,
  `Jason.encode/1` and crash reports show `"[redacted]"` or a function
  reference instead.
  """

  @default_base_url "https://api.lettermint.co/v1"
  @default_timeout 30_000
  @options [:sending_token, :team_token, :base_url, :timeout, :adapter]
  @team_token ~r/\Alm_team_[0-9A-Za-z]+\z/
  @sending_token ~r/\Alm_[0-9A-Za-z]+\z/
  @header_safe ~r/\A[\x21-\x7e]+\z/

  @enforce_keys [:base_url, :timeout, :adapter]
  defstruct [:base_url, :timeout, :adapter, :sending_token, :team_token]

  @typedoc "A token, wrapped in a closure so that it is never printed."
  @opaque secret :: (-> String.t())

  @type t :: %__MODULE__{
          base_url: String.t(),
          timeout: pos_integer(),
          adapter: module() | {module(), keyword()},
          sending_token: secret() | nil,
          team_token: secret() | nil
        }

  @doc false
  @spec new(String.t() | keyword(), keyword()) :: t()
  def new(token_or_options, options \\ [])

  def new(token, options) when is_binary(token) do
    unless Keyword.keyword?(options) do
      raise Lettermint.ConfigError, "The options argument must be a keyword list."
    end

    if Keyword.has_key?(options, :sending_token) or Keyword.has_key?(options, :team_token) do
      raise Lettermint.ConfigError,
            "Pass either a token string or the :sending_token/:team_token options, not both."
    end

    option = if detect(token) == :team, do: :team_token, else: :sending_token
    build([{option, token} | options])
  end

  def new(options, []) when is_list(options) do
    unless Keyword.keyword?(options) do
      raise Lettermint.ConfigError,
            "Pass a keyword list (sending_token: ..., team_token: ...) or a token string."
    end

    build(options)
  end

  def new(_, _) do
    raise Lettermint.ConfigError,
          "Pass a keyword list (sending_token: ..., team_token: ...) or a token string."
  end

  @doc """
  Classifies a token by its format: `lm_team_` followed by letters and digits
  is a team token, `lm_` followed by letters and digits a sending token. The
  team pattern is checked first, because every team token also starts with
  `lm_`. Raises `Lettermint.ConfigError` for any other format; the message
  never contains the token.
  """
  @spec detect(term()) :: :team | :sending
  def detect(token) do
    cond do
      is_binary(token) and Regex.match?(@team_token, token) ->
        :team

      is_binary(token) and Regex.match?(@sending_token, token) ->
        :sending

      true ->
        raise Lettermint.ConfigError,
              "Unrecognised token format; pass sending_token or team_token"
    end
  end

  defp build(options) do
    case Keyword.keys(options) -- @options do
      [] ->
        :ok

      [:api_token | _] ->
        raise Lettermint.ConfigError,
              ":api_token was removed in 2.0; pass :sending_token (project token) or :team_token (team API token)."

      [unknown | _] ->
        raise Lettermint.ConfigError,
              "Unknown option #{inspect(unknown)}; the options are #{Enum.map_join(@options, ", ", &inspect/1)}."
    end

    sending = check_token(:sending_token, Keyword.get(options, :sending_token))
    team = check_token(:team_token, Keyword.get(options, :team_token))

    if is_nil(sending) and is_nil(team) do
      raise Lettermint.ConfigError, "Pass :sending_token, :team_token or both."
    end

    %__MODULE__{
      base_url: check_base_url(Keyword.get(options, :base_url, @default_base_url)),
      timeout: check_timeout(Keyword.get(options, :timeout, @default_timeout)),
      adapter: check_adapter(Keyword.get(options, :adapter, Lettermint.Adapter.Req)),
      sending_token: sending && wrap(sending),
      team_token: team && wrap(team)
    }
  end

  defp wrap(token), do: fn -> token end

  defp check_token(_option, nil), do: nil

  defp check_token(option, token) when is_binary(token) and token != "" do
    unless Regex.match?(@header_safe, token) do
      raise Lettermint.ConfigError,
            "#{inspect(option)} contains whitespace or characters that are not allowed in an HTTP header."
    end

    token
  end

  defp check_token(option, _token),
    do: raise(Lettermint.ConfigError, "#{inspect(option)} must be a non-empty string.")

  @doc false
  def check_timeout(timeout, option \\ :timeout)
  def check_timeout(timeout, _option) when is_integer(timeout) and timeout > 0, do: timeout

  def check_timeout(_timeout, option),
    do:
      raise(
        Lettermint.ConfigError,
        "#{inspect(option)} must be a positive number of milliseconds."
      )

  defp check_base_url(url) when is_binary(url) do
    uri = URI.parse(url)

    unless uri.scheme in ["http", "https"] and uri.host not in [nil, ""] do
      raise Lettermint.ConfigError, ":base_url must be an absolute http(s) URL."
    end

    unless is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      raise Lettermint.ConfigError,
            ":base_url must not contain credentials, a query string or a fragment."
    end

    String.trim_trailing(url, "/")
  end

  defp check_base_url(_url), do: raise(Lettermint.ConfigError, ":base_url must be a string.")

  defp check_adapter(module) when is_atom(module) and not is_nil(module), do: module

  defp check_adapter({module, options} = adapter) when is_atom(module) and is_list(options),
    do: adapter

  defp check_adapter(_adapter),
    do:
      raise(
        Lettermint.ConfigError,
        ":adapter must be a module that implements Lettermint.Adapter, or {module, options}."
      )

  @doc false
  # The `{header, value}` for a surface, or a ConfigError that names the missing option.
  @spec auth_header(t(), :sending | :team | :either, String.t()) :: {String.t(), String.t()}
  def auth_header(%__MODULE__{} = client, surface, label) do
    use_team = surface == :team or (surface == :either and not is_nil(client.team_token))

    cond do
      use_team and is_nil(client.team_token) ->
        raise Lettermint.ConfigError,
              "#{label} needs :team_token; pass it as Lettermint.new(team_token: ...)."

      use_team ->
        {"authorization", "Bearer " <> client.team_token.()}

      is_nil(client.sending_token) ->
        raise Lettermint.ConfigError,
              "#{label} needs :sending_token; pass it as Lettermint.new(sending_token: ...)."

      true ->
        {"x-lettermint-token", client.sending_token.()}
    end
  end

  @doc false
  # The token values, for redacting them from error bodies.
  def tokens(%__MODULE__{} = client) do
    for secret <- [client.sending_token, client.team_token], secret, do: secret.()
  end

  @doc false
  # The configuration without credentials.
  def view(%__MODULE__{} = client) do
    [
      base_url: client.base_url,
      timeout: client.timeout,
      adapter:
        case client.adapter do
          {module, _} -> module
          module -> module
        end,
      sending_token: client.sending_token && "[redacted]",
      team_token: client.team_token && "[redacted]"
    ]
  end

  defimpl Inspect do
    def inspect(client, opts) do
      Lettermint.Redact.inspect_view("Lettermint.Client", Lettermint.Client.view(client), opts)
    end
  end

  defimpl Jason.Encoder do
    def encode(client, opts) do
      view = Map.new(Lettermint.Client.view(client))
      Jason.Encode.map(%{view | adapter: inspect(view.adapter)}, opts)
    end
  end
end

defmodule Lettermint.Redact do
  @moduledoc false
  import Inspect.Algebra

  @doc false
  # Renders `#Name<key: value, ...>` from a view that holds only loggable values.
  def inspect_view(name, view, opts) do
    container_doc(
      "##{name}<",
      view,
      ">",
      opts,
      fn {key, value}, opts ->
        concat(Atom.to_string(key) <> ": ", to_doc(value, opts))
      end,
      separator: ",",
      break: :strict
    )
  end

  @doc false
  # Replaces every token in strings (also nested in maps and lists) with "[redacted]".
  def redact(value, []), do: value

  def redact(value, tokens) when is_binary(value),
    do: Enum.reduce(tokens, value, &String.replace(&2, &1, "[redacted]"))

  def redact(value, tokens) when is_list(value), do: Enum.map(value, &redact(&1, tokens))

  def redact(value, tokens) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {redact(key, tokens), redact(item, tokens)} end)

  def redact(value, _tokens), do: value
end

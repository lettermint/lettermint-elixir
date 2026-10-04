defmodule Lettermint.Adapter do
  @moduledoc """
  The HTTP adapter behaviour.

  The default adapter is `Lettermint.Adapter.Req`. Pass another one with the
  `:adapter` client option, as a module or as `{module, options}`; `options`
  is passed to `c:request/2` (`[]` for a bare module).

  An adapter sends one request and returns the response. It must not follow
  redirects and must not retry: the SDK handles 3xx responses as
  `Lettermint.RedirectError`, so that tokens never reach another host. The
  SDK enforces the client timeout over the whole call; the adapter should use
  `request.timeout` for its own timeouts too.

  A request is a map:

    * `:method`: `:get`, `:post`, `:put`, `:patch` or `:delete`
    * `:url`: the full URL, including the encoded query string
    * `:headers`: a list of `{name, value}` with lowercase names
    * `:body`: the encoded JSON body, or `nil`
    * `:timeout`: the timeout in milliseconds

  Return `{:ok, %{status: status, headers: headers, body: body}}`, where
  `headers` is a list of `{name, value}` or a map of name to a value or a list
  of values, and `body` is a binary. Return `{:error, reason}` when no response
  arrived; `reason` is kept in `Lettermint.ConnectionError`. A reason of
  `:timeout`, or an exception with `reason: :timeout`, becomes
  `Lettermint.TimeoutError`.
  """

  @type request :: %{
          method: :get | :post | :put | :patch | :delete,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          timeout: pos_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers:
            [{String.t(), String.t()}] | %{optional(String.t()) => String.t() | [String.t()]},
          body: binary()
        }

  @callback request(request(), options :: keyword()) :: {:ok, response()} | {:error, term()}
end

defmodule Lettermint.Adapter.Req do
  @moduledoc """
  The default adapter, based on `Req`.

  It never follows redirects and never retries. Options given as
  `adapter: {Lettermint.Adapter.Req, options}` are passed to `Req.request/1`,
  for example `connect_options: [proxy: ...]`, or `plug: {Req.Test, MyStub}`
  in tests. `:redirect`, `:retry` and `:decode_body` cannot be overridden.
  """
  @behaviour Lettermint.Adapter

  @impl true
  def request(request, options) do
    forced = [
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: request.body,
      redirect: false,
      retry: false,
      decode_body: false,
      receive_timeout: request.timeout,
      connect_options:
        Keyword.merge(Keyword.get(options, :connect_options, []), timeout: request.timeout)
    ]

    case Req.request(Keyword.merge(options, forced)) do
      {:ok, response} ->
        {:ok, %{status: response.status, headers: response.headers, body: body(response.body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp body(body) when is_binary(body), do: body
  defp body(nil), do: ""
  defp body(body), do: IO.iodata_to_binary(body)
end

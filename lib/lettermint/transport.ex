defmodule Lettermint.Adapter do
  @moduledoc "HTTP adapter interface. Adapters must not follow redirects or retry requests."
  @callback request(map()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
end

defmodule Lettermint.HTTP do
  @moduledoc false
  @behaviour Lettermint.Adapter
  @impl true
  def request(request) do
    options = [
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: request.body,
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: request.timeout,
      connect_options: [timeout: request.timeout]
    ]

    case Req.request(options) do
      {:ok, response} -> {:ok, response.status, response.body}
      {:error, _} -> {:error, :connection_failed}
    end
  end
end

defmodule Lettermint.Transport do
  @moduledoc false
  def segment(value) when is_binary(value) and value not in ["", ".", ".."] do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  def segment(_), do: raise(ArgumentError, "A path ID must be a non-empty string")

  def request(%Lettermint.Client{} = client, surface, method, path, payload, type, opts) do
    if surface != :either and client.surface != surface,
      do: raise(ArgumentError, "Wrong client for this API operation")

    if Keyword.keys(opts) -- [:query, :headers, :idempotency_key] != [],
      do: raise(ArgumentError, "Unknown request option")

    headers =
      Enum.map(Keyword.get(opts, :headers, %{}), fn {key, value} ->
        key = String.downcase(to_string(key))

        if key in [
             "authorization",
             "x-lettermint-token",
             "host",
             "content-length",
             "transfer-encoding"
           ],
           do: raise(ArgumentError, "Reserved request header")

        if String.contains?(key <> to_string(value), ["\r", "\n"]),
          do: raise(ArgumentError, "Invalid request header")

        {key, to_string(value)}
      end)
      |> Map.new()

    auth =
      if client.surface == :sending,
        do: {"x-lettermint-token", client.token},
        else: {"authorization", "Bearer " <> client.token}

    headers =
      headers
      |> Map.put("accept", "application/json")
      |> Map.put("user-agent", "lettermint-elixir/#{Application.spec(:lettermint, :vsn)}")
      |> Map.put(elem(auth, 0), elem(auth, 1))

    headers =
      case Keyword.get(opts, :idempotency_key) do
        nil ->
          headers

        key when is_binary(key) and byte_size(key) > 0 ->
          if String.contains?(key, ["\r", "\n"]),
            do: raise(ArgumentError, "Invalid idempotency key")

          Map.put(headers, "idempotency-key", key)

        _ ->
          raise ArgumentError, "Invalid idempotency key"
      end

    query = URI.encode_query(Keyword.get(opts, :query, %{}))
    url = client.base_url <> path <> if(query == "", do: "", else: "?" <> query)
    body = if payload == :unset, do: nil, else: Jason.encode!(Lettermint.Model.to_map(payload))
    headers = if body, do: Map.put(headers, "content-type", "application/json"), else: headers

    result =
      try do
        client.adapter.request(%{
          method: method,
          url: url,
          body: body,
          headers: headers,
          timeout: client.timeout
        })
      rescue
        _ -> {:error, :connection_failed}
      end

    case result do
      {:ok, status, body} when status in 200..299 ->
        parse(body, type, status)

      {:ok, status, body} ->
        safe = String.replace(to_string(body), client.token, "[REDACTED]")

        data =
          case Jason.decode(safe) do
            {:ok, value} -> redact(value, client.token)
            _ -> safe
          end

        {:error,
         %Lettermint.Error{
           kind: :api,
           status: status,
           body: data,
           message: "API request failed (HTTP #{status})"
         }}

      {:error, _} ->
        {:error, %Lettermint.Error{kind: :transport, message: "HTTP request failed"}}
    end
  end

  defp redact(value, token) when is_binary(value), do: String.replace(value, token, "[REDACTED]")
  defp redact(value, token) when is_list(value), do: Enum.map(value, &redact(&1, token))

  defp redact(value, token) when is_map(value),
    do: Map.new(value, fn {key, item} -> {redact(key, token), redact(item, token)} end)

  defp redact(value, _), do: value

  defp parse(body, :raw, _), do: {:ok, body}
  defp parse(body, :ping, _), do: {:ok, String.trim(body)}
  defp parse(body, _, _) when body in [nil, ""], do: {:ok, nil}

  defp parse(body, type, status) do
    with {:ok, value} <- Jason.decode(body) do
      {:ok, Lettermint.Model.decode(value, type)}
    else
      _ ->
        {:error,
         %Lettermint.Error{kind: :decode, status: status, message: "Invalid JSON response"}}
    end
  rescue
    ArgumentError ->
      {:error,
       %Lettermint.Error{kind: :decode, status: status, message: "Invalid API response type"}}
  end
end

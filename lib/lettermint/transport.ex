defmodule Lettermint.Transport do
  @moduledoc false
  # Sends the requests of every SDK function, driven by the generated
  # operation table (Lettermint.Operations).

  alias Lettermint.{Client, Operations, Redact}

  @header_value ~r/\A[^\r\n\0]+\z/
  @excerpt 200

  @doc false
  # Raises a ConfigError when the token for the operation's surface (or `auth`) is missing.
  def assert_auth(%Client{} = client, key, label, auth \\ nil) do
    Client.auth_header(client, auth || Operations.fetch!(key).auth, label)
    :ok
  end

  @doc false
  # Options of a call: `[:timeout]`, plus `:idempotency_key` when `idempotent` is true.
  def check_options(options, label, idempotent \\ false) do
    allowed = if idempotent, do: [:timeout, :idempotency_key], else: [:timeout]

    unless Keyword.keyword?(options) do
      raise Lettermint.ConfigError, "#{label}: the options argument must be a keyword list."
    end

    case Keyword.keys(options) -- allowed do
      [] ->
        :ok

      [unknown | _] ->
        raise Lettermint.ConfigError,
              "#{label}: unknown option #{inspect(unknown)}; the options are #{Enum.map_join(allowed, ", ", &inspect/1)}."
    end

    if Keyword.has_key?(options, :timeout), do: Client.check_timeout(options[:timeout])
    options
  end

  @doc false
  def check_query(query, _label) when is_map(query) or is_nil(query), do: query

  def check_query(_query, label) do
    raise Lettermint.ConfigError,
          "#{label}: the query must be a map, for example %{page: %{size: 10}}; pass options such as :timeout in the last argument."
  end

  @doc false
  # Calls one operation. `args`: :label, :path (%{"name" => value}), :query, :body,
  # :options, :idempotent and :auth (overrides the table's surface).
  # Returns {:ok, value}, :ok (no body) or {:error, exception}; raises ConfigError.
  def call(%Client{} = client, key, args) do
    operation = Operations.fetch!(key)
    label = Map.fetch!(args, :label)
    {auth_name, auth_value} = Client.auth_header(client, args[:auth] || operation.auth, label)
    path = expand_path(operation.path, Map.get(args, :path, %{}), label)
    options = check_options(Map.get(args, :options, []), label, Map.get(args, :idempotent, false))
    timeout = Keyword.get(options, :timeout, client.timeout)
    query = Lettermint.Query.encode(check_query(Map.get(args, :query), label))

    with {:ok, headers} <- idempotency(options),
         {:ok, body} <- encode_body(Map.get(args, :body, :none)) do
      headers =
        [{"accept", "application/json"}, {"user-agent", user_agent()}] ++
          headers ++
          if(body, do: [{"content-type", "application/json"}], else: []) ++
          [{auth_name, auth_value}]

      request = %{
        method: operation.method,
        url: client.base_url <> path <> if(query == "", do: "", else: "?" <> query),
        headers: headers,
        body: body,
        timeout: timeout
      }

      case send_request(client.adapter, request, timeout) do
        {:ok, response} -> decode(operation.response.type, response, Client.tokens(client))
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc false
  # A lazy stream over every item of a cursor-paginated operation. Raises the
  # error of a failed page request.
  def paginate(%Client{} = client, key, args) do
    operation = Operations.fetch!(key)
    cursor_param = operation.pagination.cursor_param
    label = Map.fetch!(args, :label)
    Client.auth_header(client, operation.auth, label)
    check_options(Map.get(args, :options, []), label)
    query = check_query(Map.get(args, :query), label)
    expand_path(operation.path, Map.get(args, :path, %{}), label)

    Stream.resource(
      fn -> {query, MapSet.new()} end,
      fn
        :done ->
          {:halt, :done}

        {page_query, seen} ->
          case call(client, key, Map.put(args, :query, page_query)) do
            {:ok, %Lettermint.Types.CursorPage{data: data, next_cursor: next}}
            when is_list(data) ->
              if is_binary(next) and next != "" and not MapSet.member?(seen, next) do
                {data, {Lettermint.Query.put(query, cursor_param, next), MapSet.put(seen, next)}}
              else
                {data, :done}
              end

            {:ok, page} ->
              raise Lettermint.UnexpectedResponseError,
                status: 200,
                body_excerpt: excerpt(inspect(page)),
                message: "#{label}: the API returned a page without a data list."

            {:error, error} ->
              raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  defp expand_path(template, params, label) do
    Regex.replace(~r/\{(\w+)\}/, template, fn _, name ->
      case Map.get(params, name) do
        value when is_binary(value) and value not in ["", ".", ".."] ->
          URI.encode(value, &URI.char_unreserved?/1)

        _ ->
          raise Lettermint.ConfigError,
                ~s(#{label}: #{name} must be a non-empty string other than "." and "..".)
      end
    end)
  end

  defp idempotency(options) do
    case Keyword.fetch(options, :idempotency_key) do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, key} when is_binary(key) ->
        if Regex.match?(@header_value, key) do
          {:ok, [{"idempotency-key", key}]}
        else
          invalid_idempotency_key()
        end

      {:ok, _} ->
        invalid_idempotency_key()
    end
  end

  defp invalid_idempotency_key do
    {:error,
     %Lettermint.ClientValidationError{
       field: "idempotency_key",
       message: ":idempotency_key must be a non-empty string without line breaks."
     }}
  end

  defp encode_body(:none), do: {:ok, nil}

  defp encode_body(body) do
    case Jason.encode(Lettermint.Types.to_map(body)) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> body_error(error)
    end
  rescue
    error in [Protocol.UndefinedError, ArgumentError, Jason.EncodeError] -> body_error(error)
  end

  defp body_error(error) do
    detail =
      case error do
        %Protocol.UndefinedError{value: value} -> "it contains #{inspect(value, limit: 3)}"
        error -> Exception.message(error)
      end

    {:error,
     %Lettermint.ClientValidationError{
       field: "body",
       message: "The request body cannot be encoded as JSON: #{detail}"
     }}
  end

  defp user_agent do
    "lettermint-elixir/#{Application.spec(:lettermint, :vsn)}"
  end

  # Runs the adapter in a task, so that the timeout covers the whole request
  # (connecting, sending, the headers and the body) whatever the adapter does.
  defp send_request(adapter, request, timeout) do
    {module, options} =
      case adapter do
        {module, options} -> {module, options}
        module -> {module, []}
      end

    task =
      Task.async(fn ->
        try do
          module.request(request, options)
        rescue
          error -> {:error, error}
        catch
          :exit, reason -> {:error, {:exit, reason}}
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{status: status, body: body} = response}}
      when is_integer(status) and is_binary(body) ->
        {:ok, %{response | headers: headers(Map.get(response, :headers, []))}}

      {:ok, {:error, reason}} ->
        if timeout?(reason),
          do: {:error, %Lettermint.TimeoutError{timeout: timeout}},
          else: {:error, %Lettermint.ConnectionError{reason: reason}}

      {:ok, other} ->
        {:error, %Lettermint.ConnectionError{reason: {:invalid_adapter_response, other}}}

      {:exit, reason} ->
        {:error, %Lettermint.ConnectionError{reason: {:exit, reason}}}

      nil ->
        {:error, %Lettermint.TimeoutError{timeout: timeout}}
    end
  end

  defp timeout?(:timeout), do: true
  defp timeout?(%{reason: :timeout}), do: true
  defp timeout?(_), do: false

  defp headers(headers) when is_map(headers) do
    for {name, values} <- headers, value <- List.wrap(values), do: {String.downcase(name), value}
  end

  defp headers(headers) when is_list(headers) do
    for {name, value} <- headers, do: {String.downcase(to_string(name)), to_string(value)}
  end

  defp headers(_), do: []

  defp header(response, name) do
    Enum.find_value(response.headers, fn {key, value} -> if key == name, do: value end)
  end

  defp decode(type, %{status: status, body: text}, tokens) when status in 200..299 do
    cond do
      type == :empty or status in [204, 205] ->
        :ok

      type == :text ->
        {:ok, text}

      String.trim(text) == "" ->
        unexpected(
          "The Lettermint API answered with HTTP #{status} and an empty body where JSON was expected.",
          status,
          text,
          tokens
        )

      true ->
        case Jason.decode(text) do
          {:ok, value} ->
            {:ok, Lettermint.Types.decode(value, type)}

          {:error, _} ->
            unexpected(
              "The Lettermint API answered with HTTP #{status} and a body that is not valid JSON.",
              status,
              text,
              tokens
            )
        end
    end
  end

  defp decode(_type, %{status: status}, _tokens) when status in 300..399 do
    {:error, %Lettermint.RedirectError{status: status}}
  end

  defp decode(_type, %{status: status, body: text}, tokens) when status < 400 do
    unexpected(
      "The Lettermint API answered with an unexpected HTTP status #{status}.",
      status,
      text,
      tokens
    )
  end

  defp decode(_type, %{status: status, body: text} = response, tokens) do
    if String.trim(text) == "" do
      {:error, api_error(response, nil)}
    else
      case Jason.decode(text) do
        {:ok, body} ->
          {:error, api_error(response, Redact.redact(body, tokens))}

        {:error, _} ->
          content_type =
            case header(response, "content-type") do
              nil -> ""
              value -> " (#{value |> String.split(";") |> hd() |> String.trim()})"
            end

          unexpected(
            "The Lettermint API answered with HTTP #{status} and a body that is not JSON#{content_type}.",
            status,
            text,
            tokens
          )
      end
    end
  end

  defp unexpected(message, status, text, tokens) do
    {:error,
     %Lettermint.UnexpectedResponseError{
       message: message,
       status: status,
       body_excerpt: excerpt(Redact.redact(text, tokens))
     }}
  end

  defp excerpt(text) do
    if String.valid?(text) do
      if String.length(text) > @excerpt, do: String.slice(text, 0, @excerpt) <> "…", else: text
    else
      inspect(binary_part(text, 0, min(byte_size(text), @excerpt)))
    end
  end

  defp api_error(%{status: status} = response, body) do
    {code, message, details, errors} = error_fields(body)
    message = message || "HTTP #{status}"
    fields = [status: status, code: code, message: message, details: details, body: body]

    case status do
      401 ->
        struct(Lettermint.AuthenticationError, fields)

      403 ->
        struct(Lettermint.PermissionError, fields)

      404 ->
        struct(Lettermint.NotFoundError, fields)

      409 ->
        struct(Lettermint.ConflictError, fields)

      422 ->
        struct(Lettermint.ValidationError, [errors: errors] ++ fields)

      429 ->
        struct(
          Lettermint.RateLimitError,
          [retry_after: retry_after(header(response, "retry-after"))] ++ fields
        )

      status when status >= 500 ->
        struct(Lettermint.ServerError, fields)

      _ ->
        struct(Lettermint.APIError, fields)
    end
  end

  defp error_fields(body) when is_map(body) do
    {code, message, details} =
      case Map.get(body, "error") do
        %{} = error ->
          {string(error["code"]), string(error["message"]), error["details"]}

        code when is_binary(code) ->
          {code, nil, nil}

        _ ->
          {nil, nil, nil}
      end

    message = if message in [nil, ""], do: string(body["message"]), else: message
    errors = if is_map(body["errors"]), do: body["errors"], else: nil
    {code, if(message == "", do: nil, else: message), details, errors}
  end

  defp error_fields(_body), do: {nil, nil, nil, nil}

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

  @doc false
  def retry_after(nil), do: nil

  def retry_after(value) do
    value = String.trim(value)

    cond do
      Regex.match?(~r/\A\d+\z/, value) ->
        String.to_integer(value)

      date = http_date(value) ->
        max(0, DateTime.diff(date, DateTime.utc_now(), :millisecond) |> ceil_seconds())

      true ->
        nil
    end
  end

  defp ceil_seconds(milliseconds), do: div(milliseconds + 999, 1000)

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT".
  defp http_date(value) do
    with [_, day, month, year, hour, minute, second] <-
           Regex.run(~r/\A\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/, value),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <-
           NaiveDateTime.new(
             String.to_integer(year),
             index + 1,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      DateTime.from_naive!(date, "Etc/UTC")
    else
      _ -> nil
    end
  end
end

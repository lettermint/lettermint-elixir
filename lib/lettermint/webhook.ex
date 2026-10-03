defmodule Lettermint.Webhook do
  @moduledoc """
  Verifies Lettermint webhook deliveries.

  A delivery is genuine when its HMAC-SHA256 signature over `"<t>." <> raw
  body`, keyed with the endpoint's signing secret (`whsec_...`, used as is),
  matches, and its timestamp is within the tolerance:

      webhook = Lettermint.Webhook.new(System.fetch_env!("LETTERMINT_WEBHOOK_SECRET"))

      case Lettermint.Webhook.verify(webhook, raw_body, conn.req_headers) do
        {:ok, %Lettermint.WebhookPayload{event: event, data: data}} -> handle(event, data)
        {:error, %Lettermint.WebhookVerificationError{}} -> send_resp(conn, 400, "")
      end

  Pass the **raw** request body: the signature covers the exact bytes, so
  decoding and re-encoding the JSON breaks it. In Phoenix or Plug, keep the
  raw body with a `:body_reader` (see the README).

  `inspect/1` and `Jason.encode/1` show only the tolerance, never the secret.
  """

  alias Lettermint.{WebhookPayload, WebhookVerificationError}

  @signature_header "x-lettermint-signature"
  @delivery_header "x-lettermint-delivery"
  @printable_ascii ~r/\A[\x20-\x7e]*\z/
  @digits ~r/\A[0-9]+\z/
  @hex_sha256 ~r/\A[0-9a-fA-F]{64}\z/
  @max_safe_integer 9_007_199_254_740_991

  @enforce_keys [:secret, :tolerance]
  defstruct [:secret, :tolerance]

  @type t :: %__MODULE__{secret: (-> String.t()), tolerance: non_neg_integer()}

  @typedoc """
  Request headers: a map (any case; a value or a list of values), a list of
  `{name, value}` (such as `conn.req_headers`), or a `Plug.Conn`.
  """
  @type headers :: map() | [{String.t() | atom(), String.t()}] | struct()

  @doc """
  Creates a verifier for a signing secret.

  Options: `:tolerance`, the maximum difference between the signed timestamp
  and now, in seconds, in either direction (default 300; `0` accepts only the
  current second). An empty secret or a negative tolerance raises
  `Lettermint.ConfigError`.
  """
  @spec new(String.t(), tolerance: non_neg_integer()) :: t()
  def new(secret, options \\ [])

  def new(secret, options) when is_binary(secret) and secret != "" and is_list(options) do
    tolerance = Keyword.get(options, :tolerance, 300)

    unless is_integer(tolerance) and tolerance >= 0 do
      raise Lettermint.ConfigError, ":tolerance must be a non-negative whole number of seconds."
    end

    case Keyword.keys(options) -- [:tolerance] do
      [] ->
        :ok

      [unknown | _] ->
        raise Lettermint.ConfigError,
              "Unknown option #{inspect(unknown)}; the option is :tolerance."
    end

    %__MODULE__{secret: fn -> secret end, tolerance: tolerance}
  end

  def new(_secret, _options),
    do: raise(Lettermint.ConfigError, "The webhook signing secret must be a non-empty string.")

  @doc """
  Verifies a delivery from its raw body and request headers, and returns the
  decoded payload.

  Requires `X-Lettermint-Signature` (`t=<unix>,v1=<hex>`; any matching `v1`
  is accepted) and `X-Lettermint-Delivery`, which must equal the signed
  timestamp. Header names are case-insensitive.

  Options: `:now`, the current time in Unix seconds (for tests).
  """
  @spec verify(t(), binary(), headers(), now: integer()) ::
          {:ok, WebhookPayload.t()} | {:error, WebhookVerificationError.t()}
  def verify(%__MODULE__{} = webhook, raw_body, headers, options \\ []) do
    headers = header_list(headers)

    with {:ok, signature} <-
           read(
             headers,
             @signature_header,
             :signature_header_missing,
             "The X-Lettermint-Signature header is missing.",
             :signature_header_malformed,
             "The request has more than one X-Lettermint-Signature header."
           ),
         {:ok, delivery} <-
           read(
             headers,
             @delivery_header,
             :delivery_header_missing,
             "The X-Lettermint-Delivery header is missing.",
             :delivery_timestamp_mismatch,
             "The request has more than one X-Lettermint-Delivery header."
           ) do
      verify_signature(webhook, raw_body, signature, Keyword.put(options, :timestamp, delivery))
    end
  end

  @doc """
  Verifies the raw body against an `X-Lettermint-Signature` value, for setups
  where the headers are not at hand.

  Options: `:timestamp`, the `X-Lettermint-Delivery` value, which must equal
  the signed timestamp when given; `:now`, the current time in Unix seconds.
  """
  @spec verify_signature(t(), binary(), String.t(),
          timestamp: String.t() | integer(),
          now: integer()
        ) ::
          {:ok, WebhookPayload.t()} | {:error, WebhookVerificationError.t()}
  def verify_signature(%__MODULE__{} = webhook, raw_body, signature_header, options \\ []) do
    with :ok <- present(signature_header),
         {:ok, timestamp, signatures} <- parse(signature_header),
         :ok <- same_timestamp(Keyword.get(options, :timestamp), timestamp),
         :ok <- body(raw_body),
         :ok <-
           fresh(
             timestamp,
             Keyword.get_lazy(options, :now, fn -> System.os_time(:second) end),
             webhook.tolerance
           ),
         :ok <- signed(webhook, timestamp, raw_body, signatures) do
      payload(raw_body)
    end
  end

  defp error(reason, message),
    do: {:error, %WebhookVerificationError{reason: reason, message: message}}

  defp header_list(%{__struct__: Plug.Conn, req_headers: headers}), do: header_list(headers)
  defp header_list(%_{}), do: []
  defp header_list(headers) when is_map(headers), do: Map.to_list(headers)
  defp header_list(headers) when is_list(headers), do: headers
  defp header_list(_), do: []

  defp read(headers, name, missing, missing_message, ambiguous, ambiguous_message) do
    values =
      for {key, value} <- headers,
          (is_binary(key) or is_atom(key)) and String.downcase(to_string(key)) == name,
          not is_nil(value),
          item <- List.wrap(value),
          do: item

    case values do
      [] -> error(missing, missing_message)
      [value] when is_binary(value) -> {:ok, value}
      _ -> error(ambiguous, ambiguous_message)
    end
  end

  defp present(header) when is_binary(header) do
    if String.trim(header) == "",
      do: error(:signature_header_missing, "The X-Lettermint-Signature header is missing."),
      else: :ok
  end

  defp present(_),
    do: error(:signature_header_missing, "The X-Lettermint-Signature header is missing.")

  defp malformed(detail),
    do: error(:signature_header_malformed, "The signature header is malformed: #{detail}.")

  defp parse(header) do
    if Regex.match?(@printable_ascii, header) do
      header
      |> String.split(",")
      |> Enum.reduce_while({nil, []}, fn part, {timestamp, signatures} ->
        case String.split(String.trim(part), "=", parts: 2) do
          ["t", _value] when not is_nil(timestamp) ->
            {:halt, malformed("it has more than one timestamp")}

          ["t", value] ->
            if Regex.match?(@digits, value) and String.to_integer(value) <= @max_safe_integer,
              do: {:cont, {value, signatures}},
              else: {:halt, malformed("the timestamp is not a number of seconds")}

          ["v1", value] ->
            if Regex.match?(@hex_sha256, value),
              do: {:cont, {timestamp, [Base.decode16!(value, case: :mixed) | signatures]}},
              else: {:cont, {timestamp, signatures}}

          _ ->
            {:cont, {timestamp, signatures}}
        end
      end)
      |> case do
        {:error, _} = error -> error
        {nil, _} -> malformed("the timestamp (t=) is missing")
        {_, []} -> malformed("no v1 signature is present")
        {timestamp, signatures} -> {:ok, timestamp, signatures}
      end
    else
      malformed("it contains non-ASCII or control characters")
    end
  end

  defp same_timestamp(nil, _timestamp), do: :ok

  defp same_timestamp(delivery, timestamp) do
    if String.trim(to_string(delivery)) == timestamp,
      do: :ok,
      else:
        error(
          :delivery_timestamp_mismatch,
          "The X-Lettermint-Delivery header does not match the signed timestamp."
        )
  end

  defp body(raw_body) when is_binary(raw_body) and raw_body != "", do: :ok
  defp body(""), do: error(:body_invalid, "The raw request body is empty.")

  defp body(_),
    do: error(:body_invalid, "Pass the raw request body as a binary, not decoded JSON.")

  defp fresh(timestamp, now, tolerance) do
    if abs(now - String.to_integer(timestamp)) <= tolerance,
      do: :ok,
      else:
        error(
          :timestamp_out_of_tolerance,
          "The signed timestamp is outside the allowed tolerance."
        )
  end

  defp signed(webhook, timestamp, raw_body, signatures) do
    expected = :crypto.mac(:hmac, :sha256, webhook.secret.(), [timestamp, ".", raw_body])

    # Compare against every candidate, so that the time does not depend on which one matches.
    matched =
      Enum.reduce(signatures, false, fn candidate, acc ->
        :crypto.hash_equals(candidate, expected) or acc
      end)

    if matched, do: :ok, else: error(:signature_mismatch, "The webhook signature does not match.")
  end

  defp payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = payload} -> {:ok, WebhookPayload.from_map(payload)}
      {:ok, _} -> error(:payload_invalid, "The webhook payload is not a JSON object.")
      {:error, _} -> error(:payload_invalid, "The webhook payload is not valid JSON.")
    end
  end

  defimpl Inspect do
    def inspect(webhook, opts),
      do:
        Lettermint.Redact.inspect_view("Lettermint.Webhook", [tolerance: webhook.tolerance], opts)
  end

  defimpl Jason.Encoder do
    def encode(webhook, opts), do: Jason.Encode.map(%{tolerance: webhook.tolerance}, opts)
  end
end

defmodule Lettermint.WebhookPayload do
  @moduledoc """
  A verified webhook delivery.

    * `id`: the delivery id
    * `event`: the event name, for example `"message.delivered"`. Event names
      the SDK does not know pass through as strings; see
      `Lettermint.Types.WebhookEvent.values/0`.
    * `timestamp`: when the event occurred, ISO 8601
    * `data`: the event data, decoded JSON with string keys
    * `extra`: every other top-level field (such as `context`), with string keys
  """
  defstruct [:id, :event, :timestamp, data: %{}, extra: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          event: Lettermint.Types.WebhookEvent.t() | nil,
          timestamp: String.t() | nil,
          data: term(),
          extra: %{optional(String.t()) => term()}
        }

  @doc false
  def from_map(payload) do
    %__MODULE__{
      id: payload["id"],
      event: payload["event"],
      timestamp: payload["timestamp"],
      data: Map.get(payload, "data", %{}),
      extra: Map.drop(payload, ["id", "event", "timestamp", "data"])
    }
  end
end

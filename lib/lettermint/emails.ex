defmodule Lettermint.Emails do
  @moduledoc """
  Sends email with the project sending token (`x-lettermint-token`).

  Every function needs `:sending_token` on the client. Nothing about a
  message is stored on the client: every call sends exactly what it is given.

      lettermint = Lettermint.new(sending_token: System.fetch_env!("LETTERMINT_PROJECT_TOKEN"))

      {:ok, result} =
        Lettermint.Emails.send(lettermint, %{
          from: "Acme <hello@acme.com>",
          to: ["jane@example.com"],
          subject: "Welcome",
          html: "<p>Thanks for signing up.</p>"
        }, idempotency_key: "welcome-jane")

  A message is a map in the API's field names (`reply_to`, `scheduled_at`,
  `sandbox_result`, ...) with atom or string keys, or a
  `Lettermint.Types.SendMailRequest` struct. For the pipe-friendly builder,
  see `compose/2` and `Lettermint.EmailBuilder`.

  ## Attachments

  An attachment is a map with `:filename`, `:content`, and optionally
  `:content_type` and `:content_id`. `content` is base64 text, as the API
  expects it, or `{:bytes, binary}` with the raw bytes, which the SDK
  base64-encodes:

      attachments: [
        %{filename: "invoice.pdf", content: {:bytes, File.read!("invoice.pdf")}, content_type: "application/pdf"},
        %{filename: "logo.png", content: logo_base64, content_id: "logo"}
      ]

  ## Tags

  `tags` holds up to 20 name/value tags (19 when the legacy `tag` is also
  set). Names match `^[A-Za-z0-9_-]{1,32}$`, must not start with
  `__lettermint` and must be unique (case-sensitive); values match
  `^[A-Za-z0-9_-]{1,64}$`. The SDK checks this before the request and returns
  `Lettermint.ClientValidationError`.
  """

  import Kernel, except: [send: 2]

  alias Lettermint.{Client, ClientValidationError, EmailBuilder, Transport, Types}

  @tag_name ~r/\A[A-Za-z0-9_-]{1,32}\z/
  @tag_value ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @max_tags 20

  @typedoc "An email: a map in the API's field names, or a `SendMailRequest` struct."
  @type message :: map() | Types.SendMailRequest.t()

  @typedoc "`:idempotency_key` (sent as `Idempotency-Key`) and `:timeout` (milliseconds)."
  @type send_options :: [idempotency_key: String.t(), timeout: pos_integer()]

  @doc """
  Sends one email.

  Options: `:idempotency_key` (retrying with the same key does not send the
  email again) and `:timeout` in milliseconds.
  """
  @spec send(Client.t(), message(), send_options()) ::
          {:ok, Types.SendMailResponse.t()} | {:error, Lettermint.Error.t()}
  def send(%Client{} = client, message, options \\ []) do
    Transport.assert_auth(client, "POST /send", "emails.send", :sending)

    with {:ok, wire} <- prepare(message, "") do
      Transport.call(client, "POST /send", %{
        label: "emails.send",
        body: wire,
        options: options,
        idempotent: true,
        auth: :sending
      })
    end
  end

  @doc """
  Sends up to 500 emails in one request. The list may mix messages and
  builders. Takes the options of `send/3`.
  """
  @spec send_batch(Client.t(), [message() | EmailBuilder.t()], send_options()) ::
          {:ok, Types.SendBatchMailResponse.t()} | {:error, Lettermint.Error.t()}
  def send_batch(%Client{} = client, messages, options \\ []) do
    Transport.assert_auth(client, "POST /send/batch", "emails.send_batch", :sending)

    with {:ok, body} <- prepare_batch(messages) do
      Transport.call(client, "POST /send/batch", %{
        label: "emails.send_batch",
        body: body,
        options: options,
        idempotent: true,
        auth: :sending
      })
    end
  end

  @doc """
  Starts an immutable email builder. Pass a message to start from it.

  Raises `Lettermint.ConfigError` when the client has no sending token, and
  `Lettermint.ClientValidationError` when `message` is invalid.
  """
  @spec compose(Client.t(), message() | nil) :: EmailBuilder.t()
  def compose(%Client{} = client, message \\ nil) do
    Transport.assert_auth(client, "POST /send", "emails.compose", :sending)

    case prepare_draft(message || %{}, "") do
      {:ok, draft} -> %EmailBuilder{client: client, message: draft}
      {:error, error} -> raise error
    end
  end

  @doc "Checks the sending token: `GET /ping` returns `\"pong\"`."
  @spec ping(Client.t(), timeout: pos_integer()) ::
          {:ok, String.t()} | {:error, Lettermint.Error.t()}
  def ping(%Client{} = client, options \\ []) do
    with {:ok, text} <-
           Transport.call(client, "GET /ping", %{
             label: "emails.ping",
             options: options,
             auth: :sending
           }) do
      {:ok, String.trim(text)}
    end
  end

  # -- messages ---------------------------------------------------------------

  defp prepare_batch(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      result =
        case item do
          %EmailBuilder{message: draft} -> {:ok, wire(draft)}
          message -> prepare(message, "messages[#{index}]")
        end

      case result do
        {:ok, wire} -> {:cont, {:ok, [wire | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp prepare_batch(_messages),
    do:
      {:error,
       %ClientValidationError{
         field: "messages",
         message: "send_batch/3 takes a list of messages."
       }}

  # A message in wire format with binary attachment content base64-encoded.
  defp prepare(message, prefix) do
    with {:ok, draft} <- prepare_draft(message, prefix), do: {:ok, wire(draft)}
  end

  @doc false
  # Normalizes a message to string keys and validates it; attachment content may still be {:bytes, binary}.
  def prepare_draft(%Types.SendMailRequest{} = message, prefix),
    do: message |> Types.to_map() |> prepare_draft(prefix)

  def prepare_draft(message, prefix) when is_map(message) and not is_struct(message) do
    draft = normalize(message)

    case validate(draft, prefix) do
      :ok -> {:ok, draft}
      {:error, _} = error -> error
    end
  end

  def prepare_draft(_message, prefix) do
    {:error,
     %ClientValidationError{
       field: if(prefix == "", do: "message", else: prefix),
       message: "An email message must be a map or a Lettermint.Types.SendMailRequest."
     }}
  end

  @doc false
  # The wire format of a validated draft: attachment bytes become base64.
  def wire(draft) do
    case Map.fetch(draft, "attachments") do
      {:ok, attachments} when is_list(attachments) ->
        Map.put(draft, "attachments", Enum.map(attachments, &encode_attachment/1))

      _ ->
        draft
    end
  end

  defp encode_attachment(%{"content" => {:bytes, bytes}} = attachment),
    do: %{attachment | "content" => Base.encode64(bytes)}

  defp encode_attachment(attachment), do: attachment

  # String keys, ISO 8601 dates, atoms (other than booleans) as strings; {:bytes, _} is kept.
  defp normalize(%Types.SendMailRequest{} = value), do: normalize(Types.to_map(value))
  defp normalize(%Types.MessageTagInput{} = value), do: normalize(Types.to_map(value))
  defp normalize(%Types.MessageAttachmentInput{} = value), do: normalize(Types.to_map(value))
  defp normalize(%Types.SendMailRequestSettings{} = value), do: normalize(Types.to_map(value))
  defp normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize(%_{} = value), do: value
  defp normalize({:bytes, bytes}), do: {:bytes, bytes}

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key(key), normalize(value)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value

  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: key

  @doc false
  # Checks what the SDK can check before a request: tags and attachments.
  def validate(draft, prefix) do
    at = fn field -> if prefix == "", do: field, else: "#{prefix}.#{field}" end
    legacy = Map.get(draft, "tag")

    with :ok <-
           check(
             is_nil(legacy) or is_binary(legacy),
             at.("tag"),
             "The legacy tag must be a string."
           ),
         :ok <-
           validate_tags(Map.get(draft, "tags"), is_binary(legacy) and legacy != "", at.("tags")) do
      validate_attachments(Map.get(draft, "attachments"), at.("attachments"))
    end
  end

  defp check(true, _field, _message), do: :ok

  defp check(false, field, message),
    do: {:error, %ClientValidationError{field: field, message: message}}

  defp validate_tags(nil, _legacy, _field), do: :ok

  defp validate_tags(tags, legacy, field) when is_list(tags) do
    maximum = if legacy, do: @max_tags - 1, else: @max_tags

    if length(tags) > maximum do
      check(
        false,
        field,
        if(legacy,
          do: "A legacy tag and no more than #{maximum} message tags are permitted.",
          else: "No more than #{maximum} message tags are permitted."
        )
      )
    else
      Enum.reduce_while(tags, {:ok, MapSet.new()}, fn tag, {:ok, names} ->
        case validate_tag(tag, names, field) do
          {:ok, name} -> {:cont, {:ok, MapSet.put(names, name)}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp validate_tags(_tags, _legacy, field),
    do: check(false, field, "Message tags must be a list of %{name: ..., value: ...} maps.")

  defp validate_tag(%{"name" => name, "value" => value}, names, field)
       when is_binary(name) and is_binary(value) do
    cond do
      not Regex.match?(@tag_name, name) ->
        check(false, field, "Message tag names must match ^[A-Za-z0-9_-]{1,32}$.")

      String.starts_with?(String.downcase(name), "__lettermint") ->
        check(false, field, "Message tag names must not start with __lettermint.")

      not Regex.match?(@tag_value, value) ->
        check(false, field, "Message tag values must match ^[A-Za-z0-9_-]{1,64}$.")

      MapSet.member?(names, name) ->
        check(false, field, "Message tag names must be unique (case-sensitive).")

      true ->
        {:ok, name}
    end
  end

  defp validate_tag(_tag, _names, field),
    do:
      check(
        false,
        field,
        "Message tags must be %{name: ..., value: ...} maps with string values."
      )

  defp validate_attachments(nil, _field), do: :ok

  defp validate_attachments(attachments, field) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {attachment, index}, :ok ->
      at = "#{field}[#{index}]"

      result =
        case attachment do
          %{"filename" => filename} = attachment when is_binary(filename) and filename != "" ->
            case Map.get(attachment, "content") do
              content when is_binary(content) -> :ok
              {:bytes, bytes} when is_binary(bytes) -> :ok
              _ -> check(false, at, "Attachment content must be base64 text or {:bytes, binary}.")
            end

          _ ->
            check(false, at, "An attachment needs a filename.")
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp validate_attachments(_attachments, field),
    do: check(false, field, "Attachments must be a list.")
end

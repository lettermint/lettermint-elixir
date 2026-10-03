defmodule Lettermint.EmailBuilder do
  @moduledoc """
  An immutable email builder for the pipe operator. Start one with
  `Lettermint.Emails.compose/2`.

  Every function returns a new builder and leaves the one it was given
  unchanged, so a base builder can be kept and reused as a template, also
  across processes. `to/2`, `cc/2`, `bcc/2` and `reply_to/2` replace their
  list; `attach/2` appends.

      alias Lettermint.EmailBuilder, as: Email

      welcome =
        lettermint
        |> Lettermint.Emails.compose()
        |> Email.from("Acme <hello@acme.com>")
        |> Email.subject("Welcome to Acme")
        |> Email.tags([%{name: "campaign", value: "welcome"}])

      welcome |> Email.to("jane@example.com") |> Email.html("<p>Hi Jane</p>") |> Email.send()
      welcome |> Email.to("john@example.com") |> Email.html("<p>Hi John</p>") |> Email.send(idempotency_key: "welcome-john")

  A setter that gets invalid tags or attachments raises
  `Lettermint.ClientValidationError`; the builder it was given stays valid.
  `inspect/1` and `Jason.encode/1` show the message, never the client's tokens.
  """

  import Kernel, except: [send: 2]

  alias Lettermint.{ClientValidationError, Emails}

  @enforce_keys [:client]
  defstruct [:client, message: %{}]

  @type t :: %__MODULE__{client: Lettermint.Client.t(), message: map()}

  @typedoc "An attachment: `content` is base64 text or `{:bytes, binary}`."
  @type attachment :: %{
          required(:filename) => String.t(),
          required(:content) => String.t() | {:bytes, binary()},
          optional(:content_type) => String.t(),
          optional(:content_id) => String.t()
        }

  @doc "The sender, for example `Acme <hello@acme.com>`."
  @spec from(t(), String.t()) :: t()
  def from(%__MODULE__{} = builder, address) when is_binary(address),
    do: put(builder, "from", address)

  @doc "Replaces the recipients. Takes one address or a list."
  @spec to(t(), String.t() | [String.t()]) :: t()
  def to(%__MODULE__{} = builder, addresses), do: put(builder, "to", addresses(addresses))

  @doc "Replaces the CC recipients. Takes one address or a list."
  @spec cc(t(), String.t() | [String.t()]) :: t()
  def cc(%__MODULE__{} = builder, addresses), do: put(builder, "cc", addresses(addresses))

  @doc "Replaces the BCC recipients. Takes one address or a list."
  @spec bcc(t(), String.t() | [String.t()]) :: t()
  def bcc(%__MODULE__{} = builder, addresses), do: put(builder, "bcc", addresses(addresses))

  @doc "Replaces the Reply-To addresses. Takes one address or a list."
  @spec reply_to(t(), String.t() | [String.t()]) :: t()
  def reply_to(%__MODULE__{} = builder, addresses),
    do: put(builder, "reply_to", addresses(addresses))

  @doc "The subject line."
  @spec subject(t(), String.t()) :: t()
  def subject(%__MODULE__{} = builder, subject) when is_binary(subject),
    do: put(builder, "subject", subject)

  @doc "The HTML body. `nil` removes it."
  @spec html(t(), String.t() | nil) :: t()
  def html(%__MODULE__{} = builder, html) when is_binary(html) or is_nil(html),
    do: put(builder, "html", html)

  @doc "The plain-text body. `nil` removes it."
  @spec text(t(), String.t() | nil) :: t()
  def text(%__MODULE__{} = builder, text) when is_binary(text) or is_nil(text),
    do: put(builder, "text", text)

  @doc "Replaces the custom email headers."
  @spec headers(t(), %{optional(String.t() | atom()) => String.t()}) :: t()
  def headers(%__MODULE__{} = builder, headers) when is_map(headers),
    do: put(builder, "headers", headers)

  @doc "Replaces the metadata (stored with the message, not added as headers)."
  @spec metadata(t(), %{optional(String.t() | atom()) => String.t()}) :: t()
  def metadata(%__MODULE__{} = builder, metadata) when is_map(metadata),
    do: put(builder, "metadata", metadata)

  @doc "The legacy single tag. `nil` removes it."
  @spec tag(t(), String.t() | nil) :: t()
  def tag(%__MODULE__{} = builder, tag) when is_binary(tag) or is_nil(tag),
    do: put(builder, "tag", tag)

  @doc """
  Replaces the name/value tags: up to 20, or 19 with a legacy `tag/2`. Takes
  maps with `name` and `value` (atom or string keys) or
  `Lettermint.Types.MessageTagInput` structs.
  """
  @spec tags(t(), [map() | Lettermint.Types.MessageTagInput.t()]) :: t()
  def tags(%__MODULE__{} = builder, tags), do: put(builder, "tags", tags)

  @doc "The route slug to send through."
  @spec route(t(), String.t()) :: t()
  def route(%__MODULE__{} = builder, route) when is_binary(route),
    do: put(builder, "route", route)

  @doc """
  Schedules delivery. Strings are passed through (ISO 8601 or English, such
  as `"tomorrow 9am"`); a `DateTime` is sent as ISO 8601. `nil` removes it.
  """
  @spec scheduled_at(t(), String.t() | DateTime.t() | nil) :: t()
  def scheduled_at(%__MODULE__{} = builder, when_) when is_binary(when_) or is_nil(when_),
    do: put(builder, "scheduled_at", when_)

  def scheduled_at(%__MODULE__{} = builder, %DateTime{} = when_),
    do: put(builder, "scheduled_at", DateTime.to_iso8601(when_))

  @doc "Per-email settings that override the route settings (`track_opens`, `track_clicks`, `tls`)."
  @spec settings(t(), map() | Lettermint.Types.SendMailRequestSettings.t()) :: t()
  def settings(%__MODULE__{} = builder, settings) when is_map(settings),
    do: put(builder, "settings", settings)

  @doc "The result that a Sandbox project simulates for every recipient, for example `\"hard_bounced\"`."
  @spec sandbox_result(t(), Lettermint.Types.SandboxResult.t() | atom()) :: t()
  def sandbox_result(%__MODULE__{} = builder, result) when is_binary(result) or is_atom(result),
    do: put(builder, "sandbox_result", result)

  @doc """
  Adds an attachment: a map or keyword list with `:filename`, `:content`, and
  optionally `:content_type` (a MIME type, detected by the API when left out)
  and `:content_id` (for inline images referenced as `cid:<content_id>`).
  `content` is base64 text or `{:bytes, binary}` with raw bytes.

      Email.attach(builder, filename: "invoice.pdf", content: {:bytes, pdf}, content_type: "application/pdf")
  """
  @spec attach(t(), attachment() | keyword()) :: t()
  def attach(%__MODULE__{} = builder, attachment) when is_list(attachment) do
    if Keyword.keyword?(attachment) do
      attach(builder, Map.new(attachment))
    else
      invalid_attachment()
    end
  end

  def attach(%__MODULE__{} = builder, attachment) when is_map(attachment) do
    known = Map.take(attachment, [:filename, :content, :content_type, :content_id])

    next =
      for {key, value} <- known, not is_nil(value), into: %{}, do: {Atom.to_string(key), value}

    put(builder, "attachments", Map.get(builder.message, "attachments", []) ++ [next])
  end

  def attach(%__MODULE__{}, _attachment), do: invalid_attachment()

  defp invalid_attachment do
    raise ClientValidationError,
      field: "attachments",
      message:
        "attach/2 takes a map: %{filename: ..., content: ..., content_type: ..., content_id: ...}."
  end

  @doc """
  The message in the API's wire format (string keys), with attachment bytes
  base64-encoded. Contains no credentials.
  """
  @spec build(t()) :: map()
  def build(%__MODULE__{message: message}), do: Emails.wire(message)

  @doc """
  Sends a snapshot of this email. The builder is unchanged and can be sent
  again. Takes the options of `Lettermint.Emails.send/3`.
  """
  @spec send(t(), Lettermint.Emails.send_options()) ::
          {:ok, Lettermint.Types.SendMailResponse.t()} | {:error, Lettermint.Error.t()}
  def send(%__MODULE__{client: client, message: message}, options \\ []),
    do: Emails.send(client, message, options)

  defp addresses(address) when is_binary(address), do: [address]
  defp addresses(addresses) when is_list(addresses), do: addresses

  defp put(%__MODULE__{message: message} = builder, field, value) do
    message =
      if is_nil(value), do: Map.delete(message, field), else: Map.put(message, field, value)

    case Emails.prepare_draft(message, "") do
      {:ok, draft} -> %{builder | message: draft}
      {:error, error} -> raise error
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(builder, opts) do
      concat([
        "#Lettermint.EmailBuilder<",
        to_doc(Lettermint.EmailBuilder.build(builder), opts),
        ">"
      ])
    end
  end

  defimpl Jason.Encoder do
    def encode(builder, opts), do: Jason.Encode.map(Lettermint.EmailBuilder.build(builder), opts)
  end
end

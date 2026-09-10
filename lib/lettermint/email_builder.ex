defmodule Lettermint.EmailBuilder do
  @moduledoc "Build an email with the pipe operator. Each step returns a new value."
  @derive {Inspect, only: []}
  @enforce_keys [:client]
  defstruct [:client, payload: %{}]
  @type t :: %__MODULE__{client: Lettermint.Client.t(), payload: map()}
  import Kernel, except: [send: 2]

  @doc "Start an email with a project client."
  def new(%Lettermint.Client{surface: :sending} = client), do: %__MODULE__{client: client}

  for field <- [
        :from,
        :to,
        :cc,
        :bcc,
        :reply_to,
        :subject,
        :html,
        :text,
        :route,
        :headers,
        :metadata,
        :settings,
        :scheduled_at,
        :attachments
      ] do
    @doc "Set the `#{field}` field. This replaces the previous value."
    @spec unquote(field)(t(), term()) :: t()
    def unquote(field)(%__MODULE__{} = builder, value) do
      %{builder | payload: Map.put(builder.payload, unquote(field), value)}
    end
  end

  @doc "Set the legacy single tag."
  @spec tag(t(), String.t() | nil) :: t()
  def tag(%__MODULE__{} = builder, value) do
    if not is_nil(value) and length(Map.get(builder.payload, :tags, [])) >= 20,
      do: raise(ArgumentError, "A legacy tag and no more than 19 message tags are permitted")

    %{builder | payload: Map.put(builder.payload, :tag, value)}
  end

  @doc "Set typed reusable name/value tags. Maps remain supported."
  @spec tags(t(), [Lettermint.MessageTag.t() | map()]) :: t()
  def tags(%__MODULE__{} = builder, tags) when is_list(tags) do
    maximum = if is_nil(Map.get(builder.payload, :tag)), do: 20, else: 19

    if length(tags) > maximum,
      do: raise(ArgumentError, "No more than #{maximum} message tags are permitted")

    normalized =
      Enum.map(tags, fn
        %Lettermint.MessageTag{} = tag -> Lettermint.MessageTag.new!(tag.name, tag.value)
        %{name: name, value: value} -> Lettermint.MessageTag.new!(name, value)
        %{"name" => name, "value" => value} -> Lettermint.MessageTag.new!(name, value)
        _ -> raise ArgumentError, "Message tags must contain a name and value"
      end)

    names = Enum.map(normalized, & &1.name)

    if length(names) != length(Enum.uniq(names)),
      do: raise(ArgumentError, "Message tag names must be unique and case-sensitive")

    %{builder | payload: Map.put(builder.payload, :tags, normalized)}
  end

  @doc "Send the email. Request options include an idempotency key."
  def send(%__MODULE__{client: client, payload: payload}, opts \\ []),
    do: Lettermint.Email.send(client, payload, opts)

  @doc "Return the JSON data for use in a batch."
  def to_map(%__MODULE__{payload: payload}), do: Lettermint.Model.to_map(payload)
end

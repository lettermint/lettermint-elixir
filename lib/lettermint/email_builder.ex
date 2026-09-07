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
        :tag,
        :tags,
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

  @doc "Send the email. Request options include an idempotency key."
  def send(%__MODULE__{client: client, payload: payload}, opts \\ []),
    do: Lettermint.Email.send(client, payload, opts)

  @doc "Return the JSON data for use in a batch."
  def to_map(%__MODULE__{payload: payload}), do: Lettermint.Model.to_map(payload)
end

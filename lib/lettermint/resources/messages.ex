defmodule Lettermint.Messages do
  @moduledoc """
  Sent and received messages. Needs `:team_token`; `reschedule/4` and
  `cancel/3` also accept the sending token when no team token is configured.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists messages, one page at a time. `query`: `t:Lettermint.Types.ListMessagesQuery.t/0`."
  @spec list(Client.t(), Types.ListMessagesQuery.t(), keyword()) ::
          result(Types.ListMessagesResponse.t())
  def list(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /messages", %{
      label: "messages.list",
      query: query,
      options: options
    })
  end

  @doc "Streams every message, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), Types.ListMessagesQuery.t(), keyword()) ::
          Enumerable.t(Types.MessageListData.t())
  def iterate(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /messages", %{
      label: "messages.iterate",
      query: query,
      options: options
    })
  end

  @doc "Retrieves a message."
  @spec retrieve(Client.t(), String.t(), keyword()) :: result(Types.MessageData.t())
  def retrieve(%Client{} = client, message_id, options \\ []) do
    Transport.call(client, "GET /messages/{messageId}", %{
      label: "messages.retrieve",
      path: %{"messageId" => message_id},
      options: options
    })
  end

  @doc "Lists the events of a message, one page at a time."
  @spec events(Client.t(), String.t(), Types.ListMessageEventsQuery.t(), keyword()) ::
          result(Types.ListMessageEventsResponse.t())
  def events(%Client{} = client, message_id, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /messages/{messageId}/events", %{
      label: "messages.events",
      path: %{"messageId" => message_id},
      query: query,
      options: options
    })
  end

  @doc "Streams every event of a message, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate_events(Client.t(), String.t(), Types.ListMessageEventsQuery.t(), keyword()) ::
          Enumerable.t(Types.MessageEventData.t())
  def iterate_events(%Client{} = client, message_id, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /messages/{messageId}/events", %{
      label: "messages.iterate_events",
      path: %{"messageId" => message_id},
      query: query,
      options: options
    })
  end

  @doc "The raw RFC 822 source."
  @spec source(Client.t(), String.t(), keyword()) :: result(String.t())
  def source(%Client{} = client, message_id, options \\ []) do
    Transport.call(client, "GET /messages/{messageId}/source", %{
      label: "messages.source",
      path: %{"messageId" => message_id},
      options: options
    })
  end

  @doc "The HTML body."
  @spec html(Client.t(), String.t(), keyword()) :: result(String.t())
  def html(%Client{} = client, message_id, options \\ []) do
    Transport.call(client, "GET /messages/{messageId}/html", %{
      label: "messages.html",
      path: %{"messageId" => message_id},
      options: options
    })
  end

  @doc "The plain-text body."
  @spec text(Client.t(), String.t(), keyword()) :: result(String.t())
  def text(%Client{} = client, message_id, options \\ []) do
    Transport.call(client, "GET /messages/{messageId}/text", %{
      label: "messages.text",
      path: %{"messageId" => message_id},
      options: options
    })
  end

  @doc """
  Moves a scheduled message to another delivery time. Uses the team token
  when configured, otherwise the sending token.
  """
  @spec reschedule(Client.t(), String.t(), Types.RescheduleMessageRequest.t() | map(), keyword()) ::
          result(Types.ScheduledMessage.t())
  def reschedule(%Client{} = client, message_id, body, options \\ []) do
    Transport.call(client, "PATCH /messages/{messageId}", %{
      label: "messages.reschedule",
      path: %{"messageId" => message_id},
      body: body,
      options: options
    })
  end

  @doc "Cancels a scheduled message. Uses the team token when configured, otherwise the sending token."
  @spec cancel(Client.t(), String.t(), keyword()) :: result(Types.ScheduledMessage.t())
  def cancel(%Client{} = client, message_id, options \\ []) do
    Transport.call(client, "POST /messages/{messageId}/cancel", %{
      label: "messages.cancel",
      path: %{"messageId" => message_id},
      options: options
    })
  end

  @doc """
  Releases one quarantined inbound message for webhook delivery. Options:
  `:idempotency_key` and `:timeout`.
  """
  @spec process(Client.t(), String.t(), keyword()) ::
          result(Types.ProcessInboundMessageResponse.t())
  def process(%Client{} = client, message_id, options \\ []) do
    Transport.call(client, "POST /messages/{messageId}/process", %{
      label: "messages.process",
      path: %{"messageId" => message_id},
      options: options,
      idempotent: true
    })
  end
end

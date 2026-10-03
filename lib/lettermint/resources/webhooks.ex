defmodule Lettermint.Webhooks do
  @moduledoc """
  Webhook endpoints. Needs `:team_token`. Delivery attempts are in
  `Lettermint.Webhooks.Deliveries`. To verify incoming deliveries, use
  `Lettermint.Webhook`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists webhooks, one page at a time. `query`: `t:Lettermint.Types.ListWebhooksQuery.t/0`."
  @spec list(Client.t(), Types.ListWebhooksQuery.t(), keyword()) ::
          result(Types.ListWebhooksResponse.t())
  def list(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /webhooks", %{
      label: "webhooks.list",
      query: query,
      options: options
    })
  end

  @doc "Streams every webhook, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), Types.ListWebhooksQuery.t(), keyword()) ::
          Enumerable.t(Types.WebhookListData.t())
  def iterate(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /webhooks", %{
      label: "webhooks.iterate",
      query: query,
      options: options
    })
  end

  @doc "Creates a webhook. The response holds its signing secret once."
  @spec create(Client.t(), Types.StoreWebhookData.t() | map(), keyword()) ::
          result(Types.WebhookSecretResponse.t())
  def create(%Client{} = client, body, options \\ []) do
    Transport.call(client, "POST /webhooks", %{
      label: "webhooks.create",
      body: body,
      options: options
    })
  end

  @doc "Retrieves a webhook."
  @spec retrieve(Client.t(), String.t(), keyword()) :: result(Types.WebhookData.t())
  def retrieve(%Client{} = client, webhook_id, options \\ []) do
    Transport.call(client, "GET /webhooks/{webhookId}", %{
      label: "webhooks.retrieve",
      path: %{"webhookId" => webhook_id},
      options: options
    })
  end

  @doc "Updates a webhook."
  @spec update(Client.t(), String.t(), Types.UpdateWebhookData.t() | map(), keyword()) ::
          result(Types.WebhookMutationResponse.t())
  def update(%Client{} = client, webhook_id, body, options \\ []) do
    Transport.call(client, "PUT /webhooks/{webhookId}", %{
      label: "webhooks.update",
      path: %{"webhookId" => webhook_id},
      body: body,
      options: options
    })
  end

  @doc "Deletes a webhook."
  @spec delete(Client.t(), String.t(), keyword()) :: result(Types.MessageResponse.t())
  def delete(%Client{} = client, webhook_id, options \\ []) do
    Transport.call(client, "DELETE /webhooks/{webhookId}", %{
      label: "webhooks.delete",
      path: %{"webhookId" => webhook_id},
      options: options
    })
  end

  @doc "Sends a `webhook.test` delivery."
  @spec test(Client.t(), String.t(), keyword()) :: result(Types.TestWebhookResponse.t())
  def test(%Client{} = client, webhook_id, options \\ []) do
    Transport.call(client, "POST /webhooks/{webhookId}/test", %{
      label: "webhooks.test",
      path: %{"webhookId" => webhook_id},
      options: options
    })
  end

  @doc "Replaces the signing secret. The response holds the new secret once."
  @spec regenerate_secret(Client.t(), String.t(), keyword()) ::
          result(Types.WebhookSecretResponse.t())
  def regenerate_secret(%Client{} = client, webhook_id, options \\ []) do
    Transport.call(client, "POST /webhooks/{webhookId}/regenerate-secret", %{
      label: "webhooks.regenerate_secret",
      path: %{"webhookId" => webhook_id},
      options: options
    })
  end
end

defmodule Lettermint.Webhooks.Deliveries do
  @moduledoc """
  Delivery attempts of a webhook. Needs `:team_token`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists the deliveries of a webhook, one page at a time."
  @spec list(Client.t(), String.t(), Types.ListWebhookDeliveriesQuery.t(), keyword()) ::
          result(Types.ListWebhookDeliveriesResponse.t())
  def list(%Client{} = client, webhook_id, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /webhooks/{webhookId}/deliveries", %{
      label: "webhooks.deliveries.list",
      path: %{"webhookId" => webhook_id},
      query: query,
      options: options
    })
  end

  @doc "Streams every delivery of a webhook, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), String.t(), Types.ListWebhookDeliveriesQuery.t(), keyword()) ::
          Enumerable.t(Types.WebhookDeliveryListData.t())
  def iterate(%Client{} = client, webhook_id, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /webhooks/{webhookId}/deliveries", %{
      label: "webhooks.deliveries.iterate",
      path: %{"webhookId" => webhook_id},
      query: query,
      options: options
    })
  end

  @doc "Retrieves one delivery."
  @spec retrieve(Client.t(), String.t(), String.t(), keyword()) ::
          result(Types.WebhookDeliveryData.t())
  def retrieve(%Client{} = client, webhook_id, delivery_id, options \\ []) do
    Transport.call(client, "GET /webhooks/{webhookId}/deliveries/{deliveryId}", %{
      label: "webhooks.deliveries.retrieve",
      path: %{"webhookId" => webhook_id, "deliveryId" => delivery_id},
      options: options
    })
  end
end

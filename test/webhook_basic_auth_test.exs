defmodule Lettermint.WebhookBasicAuthTest do
  use ExUnit.Case, async: true
  alias Lettermint.{Model, Models}

  test "create and update keep each credential state and Bearer authentication" do
    client = Lettermint.api("fixture-token", adapter: Lettermint.TestAdapter)
    Process.put(:response, {:ok, 200, Jason.encode!(%{data: %{has_basic_auth: true}})})

    for auth <- [
          :unset,
          nil,
          %Models.WebhookBasicAuthData{username: " fixture user ", password: ""}
        ] do
      create = %Models.StoreWebhookData{
        name: "Fixture",
        url: "https://example.test/hook",
        basic_auth: auth
      }

      update = %Models.UpdateWebhookData{basic_auth: auth}
      assert {:ok, created} = Lettermint.Webhooks.create(client, create)
      assert created.data.has_basic_auth
      assert_receive {:request, request}
      assert request.method == :post
      assert request.headers["authorization"] == "Bearer fixture-token"
      refute Map.has_key?(request.headers, "x-lettermint-token")
      assert Jason.decode!(request.body) == Model.to_map(create)

      assert {:ok, updated} = Lettermint.Webhooks.update(client, "webhook-id", update)
      assert updated.data.has_basic_auth
      assert_receive {:request, request}
      assert request.method == :put
      assert request.url == "https://api.lettermint.co/v1/webhooks/webhook-id"
      body = Jason.decode!(request.body)
      assert Map.has_key?(body, "basic_auth") == (auth != :unset)
      if auth == nil, do: assert(body["basic_auth"] == nil)
      if is_map(auth), do: assert(body["basic_auth"]["password"] == "")
      decoded = Model.from_map(Models.UpdateWebhookData, body)
      assert Model.to_map(decoded) == body
    end
  end

  test "all read models expose only the safe credential flag" do
    for module <- [Models.WebhookData, Models.WebhookListData, Models.WebhookSecretData] do
      value = Model.from_map(module, %{"has_basic_auth" => true})
      assert value.has_basic_auth
      refute Map.has_key?(Model.to_map(value), "basic_auth")
    end
  end
end

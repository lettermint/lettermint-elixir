defmodule Lettermint.ClientTest do
  use ExUnit.Case, async: true
  alias Lettermint.{Model, Models, Webhook}
  defp client, do: Lettermint.email("secret-token", adapter: Lettermint.TestAdapter)

  test "user agent contains the application version" do
    assert {:ok, nil} = Lettermint.Email.send(client(), %{})
    assert_received {:request, request}

    assert request.headers["user-agent"] ==
             "lettermint-elixir/#{Application.spec(:lettermint, :vsn)}"
  end

  test "sending models preserve metadata, headers, TLS, tags, attachments, and explicit null" do
    for module <- [Models.SendMailRequest, Models.SendBatchMailRequestItem] do
      body = %{
        "from" => "sender@example.com",
        "to" => ["recipient@example.com"],
        "subject" => "test",
        "scheduled_at" => "tomorrow",
        "metadata" => %{"order" => "123"},
        "headers" => %{"X-Test" => "yes"},
        "settings" => %{"tls" => "enforced", "track_opens" => false},
        "tags" => [%{"name" => "order", "value" => "123"}],
        "attachments" => [%{"filename" => "test.txt", "content" => "dGVzdA=="}],
        "text" => nil
      }

      payload = Model.from_map(module, body)
      assert Model.to_map(payload) == body
      assert {:ok, nil} = Lettermint.Email.send(client(), payload)
      assert_received {:request, request}
      assert Jason.decode!(request.body) == body
    end
  end

  test "batch request is a bare array" do
    assert {:ok, nil} =
             Lettermint.Email.send_batch(client(), [
               %{metadata: %{id: "1"}},
               %{metadata: %{id: "2"}}
             ])

    assert_received {:request, request}

    assert Jason.decode!(request.body) == [
             %{"metadata" => %{"id" => "1"}},
             %{"metadata" => %{"id" => "2"}}
           ]
  end

  test "optional unset and explicit null are distinct" do
    assert Model.to_map(%Models.SendMailRequest{subject: "test", text: nil}) == %{
             "subject" => "test",
             "text" => nil
           }

    value =
      Model.from_map(Models.SendEmailResponse, %{
        "status" => "future_status",
        "unknown" => %{"key" => 42}
      })

    assert value.status == "future_status"
    assert value.extra == %{"unknown" => %{"key" => 42}}
    assert Model.to_map(value)["unknown"] == %{"key" => 42}
  end

  test "empty PHP maps are accepted but non-empty lists are rejected" do
    assert Model.decode([], {:map, :string}) == %{}
    assert_raise ArgumentError, fn -> Model.decode(["bad"], {:map, :string}) end
    assert Model.decode([], {:list, :string}) == []
  end

  test "raw output is unchanged and ping is trimmed" do
    Process.put(:response, {:ok, 200, "  source\r\n"})

    assert {:ok, "  source\r\n"} =
             Lettermint.Messages.source(
               Lettermint.api("token", adapter: Lettermint.TestAdapter),
               "id"
             )

    assert {:ok, "source"} = Lettermint.Email.ping(client())
  end

  test "both clients can change scheduled messages; other operations enforce scope" do
    for c <- [client(), Lettermint.api("token", adapter: Lettermint.TestAdapter)] do
      assert {:ok, nil} = Lettermint.Messages.reschedule(c, "id", %{scheduled_at: "tomorrow"})
      assert {:ok, nil} = Lettermint.Messages.cancel(c, "id")
    end

    assert_raise ArgumentError, fn -> Lettermint.Domains.list(client()) end
    assert_raise ArgumentError, fn -> Lettermint.Email.send(Lettermint.api("token"), %{}) end
  end

  test "tokens are omitted from client inspection and errors" do
    refute inspect(client()) =~ "secret-token"

    Process.put(
      :response,
      {:ok, 422, ~s({"message":"secret-token","errors":{"to":["required"]}})}
    )

    assert {:error, error} = Lettermint.Email.send(client(), %{})
    assert error.status == 422
    assert error.body["errors"]["to"] == ["required"]
    refute inspect(error) =~ "secret-token"
    Process.put(:response, {:error, %{token: "secret-token"}})
    assert {:error, error} = Lettermint.Email.ping(client())
    refute inspect(error) =~ "secret-token"
  end

  test "reserved headers, unsafe IDs, and empty tokens are rejected" do
    for header <- ["Authorization", "X-Lettermint-Token", "Host", "Content-Length"] do
      assert_raise ArgumentError, fn ->
        Lettermint.Email.ping(client(), headers: %{header => "bad"})
      end
    end

    for id <- ["", ".", "..", nil] do
      assert_raise ArgumentError, fn -> Lettermint.Messages.cancel(client(), id) end
    end

    for token <- ["", nil, " token", "token\r\n"] do
      assert_raise ArgumentError, fn -> Lettermint.email(token) end
    end
  end

  test "JSON and response type errors return error tuples" do
    for body <- ["not JSON", ~s({"message_id":42})] do
      Process.put(:response, {:ok, 202, body})
      assert {:error, %Lettermint.Error{kind: :decode}} = Lettermint.Email.send(client(), %{})
    end
  end

  test "webhook verifies raw bytes, multiple signatures, and time limits" do
    body = ~s({"name":"Café"})
    hash = :crypto.mac(:hmac, :sha256, "secret", "1000." <> body) |> Base.encode16(case: :lower)
    signature = "t=1000,v1=bad,v1=#{hash}"
    assert :ok = Webhook.verify(body, signature, "secret", now: 1300)
    assert :ok = Webhook.verify(body, signature, "secret", now: 700)

    for {b, s, key, now} <- [
          {body <> " ", signature, "secret", 1000},
          {body, signature, "wrong", 1000},
          {body, signature, "secret", 1301},
          {body, signature, "secret", 699},
          {body, signature <> ",t=1000", "secret", 1000},
          {body, "bad", "secret", 1000}
        ] do
      assert {:error, :invalid_signature} = Webhook.verify(b, s, key, now: now)
    end
  end
end

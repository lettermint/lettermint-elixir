defmodule Lettermint.WebhookTest do
  use ExUnit.Case, async: true

  alias Lettermint.{Webhook, WebhookPayload, WebhookVerificationError}

  @vectors "test/fixtures/webhooks.json" |> File.read!() |> Jason.decode!()
  @secret "whsec_test_secret_0123456789abcdef"
  @now 1_767_225_600

  defp sign(body, timestamp \\ @now, secret \\ @secret) do
    hex =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{hex}"
  end

  defp headers(body, timestamp \\ @now),
    do: %{
      "X-Lettermint-Signature" => sign(body, timestamp),
      "X-Lettermint-Delivery" => "#{timestamp}"
    }

  @body ~s({"id":"d1","event":"message.delivered","timestamp":"2026-01-01T00:00:00Z","data":{"message_id":"m"},"context":{"project_id":"p"}})

  describe "the conformance vectors" do
    for vector <- @vectors["vectors"] do
      @vector vector
      test vector["id"] do
        vector = @vector
        body = Base.decode64!(vector["body_base64"])
        webhook = Webhook.new(vector["secret"], tolerance: vector["tolerance"])
        result = Webhook.verify(webhook, body, vector["headers"], now: vector["now"])

        case vector["expect"] do
          "valid" ->
            assert {:ok, %WebhookPayload{}} = result

          "invalid" ->
            reason = String.to_existing_atom(vector["reason"])
            assert {:error, %WebhookVerificationError{reason: ^reason}} = result
        end
      end
    end
  end

  test "returns the payload" do
    webhook = Webhook.new(@secret)

    assert {:ok, payload} = Webhook.verify(webhook, @body, headers(@body), now: @now)

    assert payload == %WebhookPayload{
             id: "d1",
             event: "message.delivered",
             timestamp: "2026-01-01T00:00:00Z",
             data: %{"message_id" => "m"},
             extra: %{"context" => %{"project_id" => "p"}}
           }

    # Unknown events pass through as strings.
    body = ~s({"event":"message.teleported","data":{}})

    assert {:ok, %WebhookPayload{event: "message.teleported"}} =
             Webhook.verify(webhook, body, headers(body), now: @now)
  end

  test "accepts the common header forms, case-insensitively" do
    webhook = Webhook.new(@secret)
    signature = sign(@body)

    for headers <- [
          [{"x-lettermint-signature", signature}, {"x-lettermint-delivery", "#{@now}"}],
          %{"X-LETTERMINT-SIGNATURE" => [signature], "x-lettermint-delivery" => "#{@now}"},
          [
            x_ignored: "1",
            "X-Lettermint-Signature": signature,
            "x-lettermint-delivery": "#{@now}"
          ],
          %{
            __struct__: Plug.Conn,
            req_headers: [
              {"x-lettermint-signature", signature},
              {"x-lettermint-delivery", "#{@now}"}
            ]
          }
        ] do
      assert {:ok, _} = Webhook.verify(webhook, @body, headers, now: @now)
    end
  end

  test "requires both headers and rejects repeated ones" do
    webhook = Webhook.new(@secret)
    signature = sign(@body)

    cases = [
      {%{}, :signature_header_missing},
      {%{"x-lettermint-delivery" => "#{@now}"}, :signature_header_missing},
      {%{"x-lettermint-signature" => signature}, :delivery_header_missing},
      {[
         {"x-lettermint-signature", signature},
         {"x-lettermint-signature", signature},
         {"x-lettermint-delivery", "#{@now}"}
       ], :signature_header_malformed},
      {%{
         "x-lettermint-signature" => signature,
         "x-lettermint-delivery" => ["#{@now}", "#{@now}"]
       }, :delivery_timestamp_mismatch},
      {%{"x-lettermint-signature" => signature, "x-lettermint-delivery" => "#{@now + 1}"},
       :delivery_timestamp_mismatch},
      {%{"x-lettermint-signature" => 42, "x-lettermint-delivery" => "#{@now}"},
       :signature_header_malformed},
      {:not_headers, :signature_header_missing}
    ]

    for {headers, reason} <- cases do
      assert {:error, %WebhookVerificationError{reason: ^reason}} =
               Webhook.verify(webhook, @body, headers, now: @now),
             inspect({headers, reason})
    end
  end

  test "rejects malformed signature headers without crashing" do
    webhook = Webhook.new(@secret)
    hex = String.duplicate("a", 64)

    for header <- [
          "t=#{@now}",
          "v1=#{hex}",
          "t=abc,v1=#{hex}",
          "t=#{@now},t=#{@now},v1=#{hex}",
          "t=99999999999999999999,v1=#{hex}",
          "t=#{@now},v1=#{String.duplicate("é", 32)}",
          "t=１７６７２２５６００,v1=#{hex}",
          <<"t=", 0xFF, 0xFE>>,
          "t=#{@now},v1=#{hex}\n"
        ] do
      assert {:error, %WebhookVerificationError{reason: :signature_header_malformed}} =
               Webhook.verify_signature(webhook, @body, header, now: @now),
             inspect(header)
    end

    for header <- ["", "   ", nil] do
      assert {:error, %WebhookVerificationError{reason: :signature_header_missing}} =
               Webhook.verify_signature(webhook, @body, header, now: @now)
    end
  end

  test "checks the tolerance in both directions, at the boundary" do
    webhook = Webhook.new(@secret, tolerance: 60)

    for {timestamp, result} <- [
          {@now - 60, :ok},
          {@now + 60, :ok},
          {@now - 61, :error},
          {@now + 61, :error}
        ] do
      assert elem(Webhook.verify(webhook, @body, headers(@body, timestamp), now: @now), 0) ==
               result
    end

    assert {:error, %{reason: :timestamp_out_of_tolerance}} =
             Webhook.verify(webhook, @body, headers(@body, @now - 61), now: @now)

    # Without :now, the system clock is used.
    now = System.os_time(:second)
    assert {:ok, _} = Webhook.verify(Webhook.new(@secret), @body, headers(@body, now))
  end

  test "keeps the whsec_ prefix, accepts any matching v1 and compares the exact bytes" do
    webhook = Webhook.new(@secret)
    "t=" <> rest = sign(@body)
    [_, good] = String.split(rest, ",v1=")
    other = String.duplicate("0", 64)

    for header <- [
          "t=#{@now},v1=#{other},v1=#{good}",
          "t=#{@now},v1=#{good},v1=#{other}",
          "t=#{@now},v0=x,v1=#{String.upcase(good)}"
        ] do
      assert {:ok, _} =
               Webhook.verify_signature(webhook, @body, header, timestamp: "#{@now}", now: @now)
    end

    stripped = Webhook.new("test_secret_0123456789abcdef")

    assert {:error, %{reason: :signature_mismatch}} =
             Webhook.verify_signature(stripped, @body, sign(@body), now: @now)

    assert {:error, %{reason: :signature_mismatch}} =
             Webhook.verify_signature(webhook, @body <> " ", sign(@body), now: @now)

    assert {:ok, _} =
             Webhook.verify_signature(webhook, @body, sign(@body), timestamp: @now, now: @now)

    assert {:error, %{reason: :delivery_timestamp_mismatch}} =
             Webhook.verify_signature(webhook, @body, sign(@body), timestamp: "1", now: @now)
  end

  test "rejects bodies that are not raw JSON objects" do
    webhook = Webhook.new(@secret)

    assert {:error, %{reason: :body_invalid}} =
             Webhook.verify(webhook, "", headers(""), now: @now)

    assert {:error, %{reason: :body_invalid}} =
             Webhook.verify(webhook, %{"id" => "x"}, headers(@body), now: @now)

    for body <- ["not json", "[1,2]", "\"x\""] do
      assert {:error, %{reason: :payload_invalid}} =
               Webhook.verify(webhook, body, headers(body), now: @now)
    end
  end

  test "an empty secret or an invalid tolerance raises a ConfigError" do
    for secret <- ["", nil, 42] do
      assert_raise Lettermint.ConfigError,
                   "The webhook signing secret must be a non-empty string.",
                   fn -> Webhook.new(secret) end
    end

    for tolerance <- [-1, 1.5, "300"] do
      assert_raise Lettermint.ConfigError, fn -> Webhook.new(@secret, tolerance: tolerance) end
    end

    assert_raise Lettermint.ConfigError, fn -> Webhook.new(@secret, toleranse: 1) end
    assert Webhook.new(@secret, tolerance: 0).tolerance == 0
  end

  test "the secret appears in no debug output" do
    webhook = Webhook.new(@secret)

    {:error, error} =
      Webhook.verify_signature(webhook, "{}", "t=1,v1=#{String.duplicate("0", 64)}", now: 1)

    for value <- [webhook, error],
        output <- [
          inspect(value),
          inspect(value, structs: false, limit: :infinity),
          to_string(:io_lib.format(~c"~p", [value])),
          Exception.format(:error, error, [])
        ] do
      refute output =~ @secret
    end

    assert inspect(webhook) == "#Lettermint.Webhook<tolerance: 300>"
    assert Jason.encode!(webhook) == ~s({"tolerance":300})
  end
end

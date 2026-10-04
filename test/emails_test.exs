defmodule Lettermint.EmailsTest do
  use ExUnit.Case, async: true
  import Lettermint.TestHelpers

  alias Lettermint.{ClientValidationError, Emails, Types}
  alias Lettermint.EmailBuilder, as: Email

  defp body(request), do: Jason.decode!(request.body)

  defp message(extra \\ %{}),
    do:
      Map.merge(
        %{from: "Acme <hello@acme.com>", to: ["jane@example.com"], subject: "Hi", text: "Hello"},
        extra
      )

  describe "send/3" do
    test "posts the message in wire format with the sending token" do
      client = sending_client()

      assert {:ok, %Types.SendMailResponse{message_id: "msg", status: "pending"}} =
               Emails.send(
                 client,
                 message(%{
                   reply_to: ["r@x.co"],
                   metadata: %{order: "1"},
                   sandbox_result: :hard_bounced
                 })
               )

      assert_receive {:request, request}
      assert request.method == :post
      assert request.url == "https://api.lettermint.co/v1/send"
      assert header(request, "content-type") == "application/json"
      assert header(request, "idempotency-key") == nil

      assert body(request) == %{
               "from" => "Acme <hello@acme.com>",
               "to" => ["jane@example.com"],
               "subject" => "Hi",
               "text" => "Hello",
               "reply_to" => ["r@x.co"],
               "metadata" => %{"order" => "1"},
               "sandbox_result" => "hard_bounced"
             }
    end

    test "accepts string keys and SendMailRequest structs; nil is sent as null, :unset is left out" do
      client = sending_client()

      assert {:ok, _} =
               Emails.send(client, %{
                 "from" => "a@x.co",
                 "to" => ["b@x.co"],
                 "subject" => "s",
                 "html" => nil
               })

      assert_receive {:request, request}

      assert body(request) == %{
               "from" => "a@x.co",
               "to" => ["b@x.co"],
               "subject" => "s",
               "html" => nil
             }

      struct = %Types.SendMailRequest{
        from: "a@x.co",
        to: ["b@x.co"],
        subject: "s",
        tags: [%Types.MessageTagInput{name: "a", value: "b"}]
      }

      assert {:ok, _} = Emails.send(client, struct)
      assert_receive {:request, request}

      assert body(request) == %{
               "from" => "a@x.co",
               "to" => ["b@x.co"],
               "subject" => "s",
               "tags" => [%{"name" => "a", "value" => "b"}]
             }
    end

    test "the idempotency key is a per-call option only" do
      client = sending_client()
      assert {:ok, _} = Emails.send(client, message(), idempotency_key: "order-1")
      assert_receive {:request, request}
      assert header(request, "idempotency-key") == "order-1"

      assert {:ok, _} = Emails.send(client, message())
      assert_receive {:request, request}
      assert header(request, "idempotency-key") == nil

      for key <- ["", "a\r\nb", 42] do
        assert {:error, %ClientValidationError{field: "idempotency_key"}} =
                 Emails.send(client, message(), idempotency_key: key)
      end

      refute_received {:request, _}

      assert_raise Lettermint.ConfigError, ~r/unknown option :idempotencyKey/, fn ->
        Emails.send(client, message(), idempotencyKey: "x")
      end
    end

    test "attachments take base64 text or {:bytes, binary}" do
      client = sending_client()

      assert {:ok, _} =
               Emails.send(
                 client,
                 message(%{
                   attachments: [
                     %{filename: "a.txt", content: "YQ==", content_type: "text/plain"},
                     %{filename: "b.bin", content: {:bytes, <<0, 255, 1>>}, content_id: "b"}
                   ]
                 })
               )

      assert_receive {:request, request}

      assert body(request)["attachments"] == [
               %{"filename" => "a.txt", "content" => "YQ==", "content_type" => "text/plain"},
               %{"filename" => "b.bin", "content" => "AP8B", "content_id" => "b"}
             ]

      assert {:error,
              %ClientValidationError{
                field: "attachments[0]",
                message: "An attachment needs a filename."
              }} =
               Emails.send(client, message(%{attachments: [%{content: "YQ=="}]}))

      assert {:error, %ClientValidationError{field: "attachments[1]"}} =
               Emails.send(
                 client,
                 message(%{
                   attachments: [%{filename: "a", content: "x"}, %{filename: "b", content: 42}]
                 })
               )

      assert {:error, %ClientValidationError{field: "attachments"}} =
               Emails.send(client, message(%{attachments: "a.txt"}))
    end

    test "a body that cannot be encoded as JSON is an error, not a crash" do
      client = sending_client()

      assert {:error, %ClientValidationError{field: "body"} = error} =
               Emails.send(client, message(%{text: <<0xFF, 0xFE>>}))

      assert error.message =~ "cannot be encoded as JSON"

      assert {:error, %ClientValidationError{field: "body"}} =
               Emails.send(client, message(%{metadata: %{pid: self()}}))

      assert {:error, %ClientValidationError{field: "body"}} =
               Emails.send(client, message(%{headers: {:a, :b}}))

      refute_received {:request, _}
    end

    test "rejects a message that is not a map" do
      assert {:error, %ClientValidationError{field: "message"}} =
               Emails.send(sending_client(), "hello")

      assert {:error, %ClientValidationError{field: "message"}} =
               Emails.send(sending_client(), from: "a")
    end
  end

  describe "tag validation" do
    defp tags(count, prefix \\ "t"),
      do: for(i <- 1..count, do: %{name: "#{prefix}#{i}", value: "v"})

    test "allows 20 tags, or 19 with the legacy tag" do
      client = sending_client()
      assert {:ok, _} = Emails.send(client, message(%{tags: tags(20)}))
      assert {:ok, _} = Emails.send(client, message(%{tags: tags(19), tag: "legacy"}))

      assert {:error,
              %ClientValidationError{
                field: "tags",
                message: "No more than 20 message tags are permitted."
              }} =
               Emails.send(client, message(%{tags: tags(21)}))

      assert {:error,
              %ClientValidationError{
                message: "A legacy tag and no more than 19 message tags are permitted."
              }} =
               Emails.send(client, message(%{tags: tags(20), tag: "legacy"}))
    end

    test "checks names, values, the reserved prefix and uniqueness" do
      client = sending_client()

      cases = [
        {[%{name: "bad name", value: "v"}],
         "Message tag names must match ^[A-Za-z0-9_-]{1,32}$."},
        {[%{name: String.duplicate("a", 33), value: "v"}],
         "Message tag names must match ^[A-Za-z0-9_-]{1,32}$."},
        {[%{name: "", value: "v"}], "Message tag names must match ^[A-Za-z0-9_-]{1,32}$."},
        {[%{name: "__Lettermint_x", value: "v"}],
         "Message tag names must not start with __lettermint."},
        {[%{name: "a", value: String.duplicate("v", 65)}],
         "Message tag values must match ^[A-Za-z0-9_-]{1,64}$."},
        {[%{name: "a", value: "a b"}], "Message tag values must match ^[A-Za-z0-9_-]{1,64}$."},
        {[%{name: "a", value: "1"}, %{"name" => "a", "value" => "2"}],
         "Message tag names must be unique (case-sensitive)."},
        {[%{name: "a"}],
         "Message tags must be %{name: ..., value: ...} maps with string values."},
        {"a:b", "Message tags must be a list of %{name: ..., value: ...} maps."}
      ]

      for {tags, message} <- cases do
        assert {:error, %ClientValidationError{field: "tags", message: ^message}} =
                 Emails.send(client, message(%{tags: tags}))
      end

      assert {:ok, _} =
               Emails.send(
                 client,
                 message(%{tags: [%{name: "A", value: "1"}, %{name: "a", value: "1"}]})
               )

      assert {:error, %ClientValidationError{field: "tag"}} =
               Emails.send(client, message(%{tag: 42}))
    end
  end

  describe "send_batch/3" do
    test "sends maps and builders in one request with a per-call key" do
      client =
        sending_client(
          json(202, [
            %{message_id: "1", status: "pending"},
            %{message_id: "2", status: "scheduled", scheduled_at: "2026-10-04T09:00:00Z"}
          ])
        )

      builder =
        client
        |> Emails.compose()
        |> Email.from("a@x.co")
        |> Email.to("b@x.co")
        |> Email.subject("Built")

      assert {:ok,
              [
                %Types.SendMailResponse{message_id: "1"},
                %Types.SendMailResponse{status: "scheduled", scheduled_at: "2026-10-04T09:00:00Z"}
              ]} =
               Emails.send_batch(client, [message(), builder], idempotency_key: "batch-1")

      assert_receive {:request, request}
      assert request.url == "https://api.lettermint.co/v1/send/batch"
      assert header(request, "idempotency-key") == "batch-1"
      assert [%{"subject" => "Hi"}, %{"subject" => "Built", "to" => ["b@x.co"]}] = body(request)
    end

    test "names the failing message" do
      assert {:error, %ClientValidationError{field: "messages[1].tags"}} =
               Emails.send_batch(sending_client(), [
                 message(),
                 message(%{tags: [%{name: "!", value: "x"}]})
               ])

      assert {:error, %ClientValidationError{field: "messages"}} =
               Emails.send_batch(sending_client(), %{})
    end
  end

  describe "the builder" do
    test "every setter returns a new builder and leaves the original unchanged" do
      client = sending_client()

      base =
        client
        |> Emails.compose()
        |> Email.from("Acme <hello@acme.com>")
        |> Email.subject("Welcome")

      jane = base |> Email.to("jane@example.com") |> Email.html("<p>Hi Jane</p>")
      john = base |> Email.to(["john@example.com", "j2@example.com"]) |> Email.cc("c@x.co")

      assert Email.build(base) == %{"from" => "Acme <hello@acme.com>", "subject" => "Welcome"}
      assert Email.build(jane)["to"] == ["jane@example.com"]
      assert Email.build(john)["to"] == ["john@example.com", "j2@example.com"]
      refute Map.has_key?(Email.build(jane), "cc")

      assert {:ok, _} = Email.send(jane, idempotency_key: "welcome-jane")
      assert {:ok, _} = Email.send(john)
      assert_receive {:request, first}
      assert_receive {:request, second}
      assert body(first)["html"] == "<p>Hi Jane</p>"
      assert header(first, "idempotency-key") == "welcome-jane"
      refute Map.has_key?(body(second), "html")
      assert header(second, "idempotency-key") == nil

      # The same builder can be sent again.
      assert {:ok, _} = Email.send(jane)
      assert_receive {:request, third}
      assert body(third) == body(first)
    end

    test "builders are safe to use from concurrent processes" do
      client = sending_client()
      base = client |> Emails.compose() |> Email.from("a@x.co") |> Email.subject("Concurrent")

      1..20
      |> Enum.map(fn i ->
        Task.async(fn ->
          Process.sleep(rem(i, 3))

          base
          |> Email.to("user#{i}@x.co")
          |> Email.text("#{i}")
          |> Email.send(idempotency_key: "k#{i}")
        end)
      end)
      |> Task.await_many()

      for _ <- 1..20 do
        assert_receive {:request, request}
        %{"to" => [to], "text" => text} = body(request)
        assert to == "user#{text}@x.co"
        assert header(request, "idempotency-key") == "k#{text}"
      end
    end

    test "an invalid setter raises and leaves the builder it was given unchanged" do
      builder =
        sending_client()
        |> Emails.compose()
        |> Email.from("a@x.co")
        |> Email.tags([%{name: "ok", value: "1"}])

      error =
        assert_raise ClientValidationError, fn ->
          Email.tags(builder, [%{name: "not valid!", value: "x"}])
        end

      assert error.field == "tags"
      assert Email.build(builder)["tags"] == [%{"name" => "ok", "value" => "1"}]

      assert_raise ClientValidationError, fn -> Email.attach(builder, %{content: "x"}) end
      assert_raise ClientValidationError, fn -> Email.attach(builder, [:not_a_keyword]) end
      assert_raise ClientValidationError, fn -> Email.attach(builder, "file.txt") end

      assert_raise ClientValidationError, fn ->
        Email.tag(
          Email.tags(builder, for(i <- 1..20, do: %{name: "t#{i}", value: "v"})),
          "legacy"
        )
      end

      assert Email.build(builder) == %{
               "from" => "a@x.co",
               "tags" => [%{"name" => "ok", "value" => "1"}]
             }
    end

    test "covers every field; nil removes a field" do
      at = ~U[2026-10-04 09:00:00Z]

      builder =
        sending_client()
        |> Emails.compose()
        |> Email.from("a@x.co")
        |> Email.to("b@x.co")
        |> Email.cc("c@x.co")
        |> Email.bcc(["d@x.co"])
        |> Email.reply_to("r@x.co")
        |> Email.subject("S")
        |> Email.html("<p>h</p>")
        |> Email.text("t")
        |> Email.headers(%{"X-Custom" => "1"})
        |> Email.metadata(%{order: "1"})
        |> Email.tag("legacy")
        |> Email.tags([%Types.MessageTagInput{name: "campaign", value: "welcome"}])
        |> Email.route("outgoing")
        |> Email.scheduled_at(at)
        |> Email.settings(%{track_opens: false, tls: "enforced"})
        |> Email.sandbox_result("delivered")
        |> Email.attach(
          filename: "a.pdf",
          content: {:bytes, "pdf"},
          content_type: "application/pdf"
        )
        |> Email.attach(%{filename: "logo.png", content: "bG9nbw==", content_id: "logo"})

      assert Email.build(builder) == %{
               "from" => "a@x.co",
               "to" => ["b@x.co"],
               "cc" => ["c@x.co"],
               "bcc" => ["d@x.co"],
               "reply_to" => ["r@x.co"],
               "subject" => "S",
               "html" => "<p>h</p>",
               "text" => "t",
               "headers" => %{"X-Custom" => "1"},
               "metadata" => %{"order" => "1"},
               "tag" => "legacy",
               "tags" => [%{"name" => "campaign", "value" => "welcome"}],
               "route" => "outgoing",
               "scheduled_at" => "2026-10-04T09:00:00Z",
               "settings" => %{"track_opens" => false, "tls" => "enforced"},
               "sandbox_result" => "delivered",
               "attachments" => [
                 %{
                   "filename" => "a.pdf",
                   "content" => "cGRm",
                   "content_type" => "application/pdf"
                 },
                 %{"filename" => "logo.png", "content" => "bG9nbw==", "content_id" => "logo"}
               ]
             }

      cleared =
        builder |> Email.html(nil) |> Email.text(nil) |> Email.tag(nil) |> Email.scheduled_at(nil)

      for field <- ["html", "text", "tag", "scheduled_at"],
          do: refute(Map.has_key?(Email.build(cleared), field))
    end

    test "compose/2 starts from a message and validates it" do
      client = sending_client()
      builder = Emails.compose(client, message(%{tags: [%{name: "a", value: "b"}]}))
      assert Email.build(builder)["tags"] == [%{"name" => "a", "value" => "b"}]

      assert_raise ClientValidationError, fn ->
        Emails.compose(client, message(%{tags: [%{name: "a b", value: "b"}]}))
      end
    end

    test "shows the message in debug output but never the tokens" do
      builder = client() |> Emails.compose() |> Email.from("a@x.co") |> Email.subject("Debug")

      for output <- [
            inspect(builder),
            inspect(builder, structs: false, limit: :infinity),
            to_string(:io_lib.format(~c"~p", [builder])),
            Jason.encode!(builder)
          ] do
        refute output =~ sending_token()
        refute output =~ team_token()
      end

      assert inspect(builder) =~
               ~s(#Lettermint.EmailBuilder<%{"from" => "a@x.co", "subject" => "Debug"}>)

      assert Jason.decode!(Jason.encode!(builder)) == %{"from" => "a@x.co", "subject" => "Debug"}
    end
  end
end

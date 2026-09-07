defmodule Lettermint.BuilderTest do
  use ExUnit.Case, async: true
  alias Lettermint.EmailBuilder, as: Email

  test "pipe builder keeps independent messages and supports batch payloads" do
    base =
      Lettermint.email("token", adapter: Lettermint.TestAdapter)
      |> Email.new()
      |> Email.from("a@example.com")

    first =
      base
      |> Email.to(["b@example.com"])
      |> Email.subject("First")
      |> Email.metadata(%{order: "1"})

    second = base |> Email.to(["c@example.com"]) |> Email.subject("Second")
    assert Email.to_map(first)["subject"] == "First"
    assert Email.to_map(second)["subject"] == "Second"
    refute Map.has_key?(Email.to_map(base), "subject")
    assert {:ok, nil} = Email.send(first, idempotency_key: "first")
    assert_received {:request, request}
    assert request.headers["idempotency-key"] == "first"
    assert Jason.decode!(request.body) == Email.to_map(first)
    refute inspect(first) =~ "token"
  end

  test "error redaction handles JSON escaped token text" do
    Process.put(:response, {:ok, 401, ~S({"message":"test\u002Dtoken"})})

    assert {:error, error} =
             Lettermint.Email.ping(
               Lettermint.email("test-token", adapter: Lettermint.TestAdapter)
             )

    assert error.body["message"] == "[REDACTED]"
  end
end

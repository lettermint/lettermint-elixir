defmodule Lettermint.HTTPTest do
  use ExUnit.Case, async: true

  defp server(status, body, headers) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(socket)
    owner = self()

    task =
      Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(socket, 5000)
        {:ok, head} = read_headers(connection, "")
        [prefix, rest] = String.split(head, "\r\n\r\n", parts: 2)

        length =
          case Regex.run(~r/content-length: (\d+)/i, prefix) do
            [_, size] -> String.to_integer(size)
            _ -> 0
          end

        tail =
          if byte_size(rest) < length do
            {:ok, more} = :gen_tcp.recv(connection, length - byte_size(rest), 5000)
            rest <> more
          else
            rest
          end

        send(owner, {:wire, prefix, tail})

        :ok =
          :gen_tcp.send(
            connection,
            "HTTP/1.1 #{status} Test\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n#{headers}\r\n#{body}"
          )

        :gen_tcp.close(connection)
        # A second connection means that the adapter followed a redirect or retried.
        result = :gen_tcp.accept(socket, 200)
        :gen_tcp.close(socket)
        result
      end)

    {"http://127.0.0.1:#{port}/v1", task}
  end

  defp read_headers(socket, data) do
    if String.contains?(data, "\r\n\r\n") do
      {:ok, data}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5000)
      read_headers(socket, data <> chunk)
    end
  end

  test "Req sends the expected JSON, token, and idempotency header" do
    {url, task} =
      server(
        202,
        ~s({"message_id":"id","status":"pending"}),
        "Content-Type: application/json\r\n"
      )

    client = Lettermint.email("local-test-token", base_url: url)

    assert {:ok, value} =
             Lettermint.Email.send(
               client,
               %{from: "a@example.com", to: ["b@example.com"], subject: "test"},
               idempotency_key: "local-id"
             )

    assert value.message_id == "id"
    assert_receive {:wire, head, body}, 1000
    assert head =~ "POST /v1/send HTTP/1.1"
    assert String.downcase(head) =~ "x-lettermint-token: local-test-token"
    assert String.downcase(head) =~ "idempotency-key: local-id"
    assert Jason.decode!(body)["subject"] == "test"
    assert {:error, :timeout} = Task.await(task)
  end

  test "Req does not retry 429 or 503 responses or follow redirects" do
    for status <- [302, 429, 503] do
      {url, task} = server(status, "failure", "Location: /next\r\nRetry-After: 0\r\n")

      assert {:error, %Lettermint.Error{status: ^status}} =
               Lettermint.Email.ping(Lettermint.email("token", base_url: url))

      assert {:error, :timeout} = Task.await(task)
    end
  end

  test "connection errors return a transport error" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)

    assert {:error, %Lettermint.Error{kind: :transport}} =
             Lettermint.Email.ping(
               Lettermint.email("token", base_url: "http://127.0.0.1:#{port}/v1", timeout: 100)
             )
  end
end

defmodule Lettermint.HTTPTest do
  # Drives the default Req adapter against a local socket server.
  use ExUnit.Case, async: true
  import Lettermint.TestHelpers, only: [sending_token: 0, team_token: 0]

  # Accepts one connection, reports the request and answers with `respond`.
  # A second connection within 300 ms is reported too: it means the client
  # followed a redirect or retried.
  defp server(respond) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(socket)
    owner = self()

    task =
      Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(socket, 5_000)
        {head, body} = read_request(connection)
        send(owner, {:wire, head, body})
        respond.(connection)
        :gen_tcp.close(connection)
        second = :gen_tcp.accept(socket, 300)
        :gen_tcp.close(socket)
        second
      end)

    {"http://127.0.0.1:#{port}/v1", task}
  end

  defp read_request(connection, data \\ "") do
    if String.contains?(data, "\r\n\r\n") do
      [head, rest] = String.split(data, "\r\n\r\n", parts: 2)

      length =
        case Regex.run(~r/content-length: (\d+)/i, head) do
          [_, size] -> String.to_integer(size)
          _ -> 0
        end

      if byte_size(rest) < length do
        {:ok, more} = :gen_tcp.recv(connection, length - byte_size(rest), 5_000)
        {head, rest <> more}
      else
        {head, rest}
      end
    else
      {:ok, chunk} = :gen_tcp.recv(connection, 0, 5_000)
      read_request(connection, data <> chunk)
    end
  end

  defp reply(status, body, headers \\ "") do
    fn connection ->
      :gen_tcp.send(
        connection,
        "HTTP/1.1 #{status} Test\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n#{headers}\r\n#{body}"
      )
    end
  end

  test "sends the JSON body, the token and the idempotency key" do
    {url, task} =
      server(
        reply(
          202,
          ~s({"message_id":"id","status":"pending"}),
          "Content-Type: application/json\r\n"
        )
      )

    client = Lettermint.new(sending_token: sending_token(), base_url: url)

    assert {:ok, %{message_id: "id"}} =
             Lettermint.Emails.send(client, %{from: "a@x.co", to: ["b@x.co"], subject: "test"},
               idempotency_key: "local-id"
             )

    assert_receive {:wire, head, body}, 1_000
    assert head =~ "POST /v1/send HTTP/1.1"
    assert String.downcase(head) =~ "x-lettermint-token: #{String.downcase(sending_token())}"
    assert String.downcase(head) =~ "idempotency-key: local-id"
    refute String.downcase(head) =~ "authorization"
    assert Jason.decode!(body)["subject"] == "test"
    assert {:error, :timeout} = Task.await(task)
  end

  test "does not follow redirects or retry 429 and 503 responses" do
    for {status, error} <- [
          {302, Lettermint.RedirectError},
          {307, Lettermint.RedirectError},
          {429, Lettermint.RateLimitError},
          {503, Lettermint.ServerError}
        ] do
      {url, task} = server(reply(status, "", "Location: /v1/elsewhere\r\nRetry-After: 0\r\n"))
      client = Lettermint.new(team_token: team_token(), base_url: url)
      assert {:error, %^error{status: ^status}} = Lettermint.ping(client)
      assert {:error, :timeout} = Task.await(task)
    end
  end

  test "the timeout covers a body that arrives too slowly" do
    slow_body = fn connection ->
      :gen_tcp.send(
        connection,
        "HTTP/1.1 200 OK\r\nContent-Length: 20\r\nContent-Type: application/json\r\n\r\n{"
      )

      for _ <- 1..10 do
        Process.sleep(60)
        :gen_tcp.send(connection, " ")
      end
    end

    {url, _task} = server(slow_body)
    client = Lettermint.new(team_token: team_token(), base_url: url, timeout: 250)
    started = System.monotonic_time(:millisecond)
    assert {:error, %Lettermint.TimeoutError{timeout: 250}} = Lettermint.Team.retrieve(client)
    assert System.monotonic_time(:millisecond) - started < 500
  end

  test "a refused connection is a ConnectionError that keeps the reason" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)

    client =
      Lettermint.new(
        team_token: team_token(),
        base_url: "http://127.0.0.1:#{port}/v1",
        timeout: 1_000
      )

    assert {:error,
            %Lettermint.ConnectionError{reason: %Req.TransportError{reason: :econnrefused}}} =
             Lettermint.ping(client)
  end

  test "Req options pass through the adapter tuple" do
    {url, task} = server(reply(200, "pong"))

    client =
      Lettermint.new(
        team_token: team_token(),
        base_url: url,
        adapter: {Lettermint.Adapter.Req, headers: [{"x-extra", "1"}], redirect: true}
      )

    assert {:ok, "pong"} = Lettermint.ping(client)
    assert_receive {:wire, head, _}, 1_000
    refute head =~ "x-extra"
    assert {:error, :timeout} = Task.await(task)
  end
end

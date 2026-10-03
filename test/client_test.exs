defmodule Lettermint.ClientTest do
  use ExUnit.Case, async: true
  import Lettermint.TestHelpers

  alias Lettermint.ConfigError

  describe "new/1 with options" do
    test "takes a sending token, a team token or both" do
      assert %Lettermint.Client{} = Lettermint.new(sending_token: sending_token())
      assert %Lettermint.Client{} = Lettermint.new(team_token: team_token())
      client = Lettermint.new(sending_token: sending_token(), team_token: team_token())
      assert client.base_url == "https://api.lettermint.co/v1"
      assert client.timeout == 30_000
      assert client.adapter == Lettermint.Adapter.Req
    end

    test "needs at least one token" do
      assert_raise ConfigError, "Pass :sending_token, :team_token or both.", fn ->
        Lettermint.new([])
      end

      assert_raise ConfigError, fn -> Lettermint.new(timeout: 1000) end
    end

    test "explicit tokens may have any format, but must be header-safe and non-empty" do
      assert %Lettermint.Client{} = Lettermint.new(sending_token: "lm_sso_anything")

      assert_raise ConfigError, ":team_token must be a non-empty string.", fn ->
        Lettermint.new(team_token: "")
      end

      assert_raise ConfigError, ":sending_token must be a non-empty string.", fn ->
        Lettermint.new(sending_token: 42)
      end

      error = assert_raise ConfigError, fn -> Lettermint.new(sending_token: "lm_abc\r\nx: y") end
      assert error.message =~ "not allowed in an HTTP header"
      refute error.message =~ "lm_abc"
    end

    test "rejects unknown options and the removed :api_token" do
      assert_raise ConfigError, ~r/Unknown option :timout/, fn ->
        Lettermint.new(sending_token: sending_token(), timout: 1)
      end

      assert_raise ConfigError, ~r/:api_token was removed in 2.0/, fn ->
        Lettermint.new(api_token: "lm_x")
      end
    end

    test "validates base_url, timeout and adapter" do
      token = [sending_token: sending_token()]

      assert Lettermint.new(token ++ [base_url: "http://localhost:4000/v1/"]).base_url ==
               "http://localhost:4000/v1"

      for url <- [
            "ftp://x",
            "api.lettermint.co",
            "https://user:pass@x/v1",
            "https://x/v1?a=1",
            "https://x/v1#f",
            42
          ] do
        assert_raise ConfigError, fn -> Lettermint.new(token ++ [base_url: url]) end
      end

      for timeout <- [0, -1, 1.5, "1000", :infinity] do
        assert_raise ConfigError, ":timeout must be a positive number of milliseconds.", fn ->
          Lettermint.new(token ++ [timeout: timeout])
        end
      end

      assert Lettermint.new(token ++ [adapter: {Lettermint.TestAdapter, []}]).adapter ==
               {Lettermint.TestAdapter, []}

      assert_raise ConfigError, fn -> Lettermint.new(token ++ [adapter: "Req"]) end
    end

    test "rejects arguments that are neither a keyword list nor a token" do
      assert_raise ConfigError, fn -> Lettermint.new(%{sending_token: sending_token()}) end
      assert_raise ConfigError, fn -> Lettermint.new(nil) end
      assert_raise ConfigError, fn -> Lettermint.new([1, 2]) end
    end
  end

  describe "token string shorthand" do
    test "detects team tokens first, then sending tokens" do
      assert %{team_token: team, sending_token: nil} = Lettermint.new("lm_team_Abc123")
      assert team.() == "lm_team_Abc123"
      assert %{sending_token: sending, team_token: nil} = Lettermint.new("lm_Abc123")
      assert sending.() == "lm_Abc123"
      assert Lettermint.Client.detect("lm_team_x9") == :team
      assert Lettermint.Client.detect("lm_teamx9") == :sending
    end

    test "rejects every other format without echoing the token" do
      for token <- [
            "lm_sso_Abc123",
            "lm_team_",
            "lm_",
            "",
            "sk_live_abc",
            "eyJhbGciOiJIUzI1NiJ9.e30.c2ln",
            "lm_abc-def",
            " lm_abc",
            "LM_abc"
          ] do
        error = assert_raise ConfigError, fn -> Lettermint.new(token) end
        assert error.message == "Unrecognised token format; pass sending_token or team_token"
        if token != "", do: refute(error.message =~ token)
      end

      assert_raise ConfigError, fn -> Lettermint.new(nil) end
      assert_raise ConfigError, fn -> Lettermint.new(42) end
    end

    test "takes other options in the second argument" do
      client = Lettermint.new("lm_team_Abc123", timeout: 5_000, base_url: "http://127.0.0.1:1/v1")
      assert client.timeout == 5_000
      assert client.base_url == "http://127.0.0.1:1/v1"
    end

    test "does not combine a token string with token options" do
      assert_raise ConfigError, ~r/either a token string or/, fn ->
        Lettermint.new("lm_Abc123", team_token: team_token())
      end

      assert_raise ConfigError, ~r/keyword list/, fn ->
        Lettermint.new("lm_Abc123", %{timeout: 1})
      end
    end
  end

  describe "per-surface tokens" do
    test "emails use the sending token header and the Team API the bearer token" do
      client =
        client([], fn request ->
          if path(request) == "/v1/send",
            do: json(202, %{message_id: "m", status: "pending"}),
            else: json(200, %{data: [], next_cursor: nil})
        end)

      assert {:ok, _} =
               Lettermint.Emails.send(client, %{
                 from: "a@x.co",
                 to: ["b@x.co"],
                 subject: "s",
                 text: "t"
               })

      assert_receive {:request, request}
      assert header(request, "x-lettermint-token") == sending_token()
      assert header(request, "authorization") == nil

      assert {:ok, _} = Lettermint.Domains.list(client)
      assert_receive {:request, request}
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert header(request, "x-lettermint-token") == nil
    end

    test "never falls back to the other token" do
      sending = sending_client()
      team = team_client()

      assert_raise ConfigError,
                   "domains.list needs :team_token; pass it as Lettermint.new(team_token: ...).",
                   fn ->
                     Lettermint.Domains.list(sending)
                   end

      assert_raise ConfigError, ~r/analytics needs :team_token/, fn ->
        Lettermint.analytics(sending, %{})
      end

      assert_raise ConfigError, ~r/webhooks.deliveries.iterate needs :team_token/, fn ->
        Lettermint.Webhooks.Deliveries.iterate(sending, "w")
      end

      assert_raise ConfigError,
                   "emails.send needs :sending_token; pass it as Lettermint.new(sending_token: ...).",
                   fn ->
                     Lettermint.Emails.send(team, %{})
                   end

      assert_raise ConfigError, ~r/emails.compose needs :sending_token/, fn ->
        Lettermint.Emails.compose(team)
      end

      assert_raise ConfigError, ~r/emails.send_batch needs :sending_token/, fn ->
        Lettermint.Emails.send_batch(team, [])
      end

      assert_raise ConfigError, ~r/emails.ping needs :sending_token/, fn ->
        Lettermint.Emails.ping(team)
      end

      refute_received {:request, _}
    end

    test "ping, reschedule and cancel use the team token when set, otherwise the sending token" do
      pong = raw(200, "pong\n", [{"content-type", "text/html; charset=UTF-8"}])
      scheduled = json(200, %{message_id: "m", status: "canceled", scheduled_at: nil})

      for {client, header, value} <- [
            {client([], pong), "authorization", "Bearer " <> team_token()},
            {sending_client(pong), "x-lettermint-token", sending_token()},
            {team_client(pong), "authorization", "Bearer " <> team_token()}
          ] do
        assert {:ok, "pong"} = Lettermint.ping(client)
        assert_receive {:request, request}
        assert header(request, header) == value
      end

      for {client, header, value} <- [
            {client([], scheduled), "authorization", "Bearer " <> team_token()},
            {sending_client(scheduled), "x-lettermint-token", sending_token()},
            {team_client(scheduled), "authorization", "Bearer " <> team_token()}
          ] do
        assert {:ok, %Lettermint.Types.ScheduledMessage{status: "canceled"}} =
                 Lettermint.Messages.cancel(client, "m")

        assert_receive {:request, request}
        assert header(request, header) == value
        assert {:ok, _} = Lettermint.Messages.reschedule(client, "m", %{scheduled_at: "tomorrow"})
        assert_receive {:request, request}
        assert header(request, header) == value
      end

      # emails.ping always uses the sending token.
      assert {:ok, "pong"} = Lettermint.Emails.ping(client([], pong))
      assert_receive {:request, request}
      assert header(request, "x-lettermint-token") == sending_token()
      assert header(request, "authorization") == nil
    end
  end

  describe "debug output" do
    test "never shows the tokens" do
      client = client()
      both = Lettermint.new(sending_token: sending_token(), team_token: team_token())

      for value <- [client, both] do
        outputs = [
          inspect(value),
          inspect(value, structs: false, limit: :infinity, printable_limit: :infinity),
          inspect(value, pretty: true, limit: :infinity),
          to_string(:io_lib.format(~c"~p", [value])),
          to_string(:io_lib.format(~c"~w", [value])),
          Jason.encode!(value)
        ]

        for output <- outputs do
          refute output =~ sending_token()
          refute output =~ team_token()
        end
      end

      assert inspect(both) =~ ~s(sending_token: "[redacted]")

      assert Jason.decode!(Jason.encode!(both)) == %{
               "adapter" => "Lettermint.Adapter.Req",
               "base_url" => "https://api.lettermint.co/v1",
               "sending_token" => "[redacted]",
               "team_token" => "[redacted]",
               "timeout" => 30_000
             }

      error = assert_raise Protocol.UndefinedError, fn -> to_string(both) end
      refute Exception.message(error) =~ team_token()
    end

    test "sends a User-Agent with the SDK version" do
      client = client()
      Lettermint.Domains.list(client)
      assert_receive {:request, request}

      assert header(request, "user-agent") ==
               "lettermint-elixir/#{Application.spec(:lettermint, :vsn)}"

      assert header(request, "accept") == "application/json"
    end
  end
end

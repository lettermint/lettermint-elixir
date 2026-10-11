defmodule Lettermint.TransportTest do
  use ExUnit.Case, async: true
  import Lettermint.TestHelpers
  require Lettermint.Error

  alias Lettermint.Types

  describe "responses" do
    test "204 returns :ok" do
      client = team_client(raw(204, ""))
      assert :ok = Lettermint.Projects.ReportForwarding.delete(client, "p")
      assert_receive {:request, request}
      assert request.method == :delete
      assert path(request) == "/v1/projects/p/report-forwarding"
    end

    test "text endpoints return the body as is; ping is trimmed" do
      client = team_client(raw(200, "<p>Hi</p>\n", [{"content-type", "text/html"}]))
      assert {:ok, "<p>Hi</p>\n"} = Lettermint.Messages.html(client, "m")
      assert {:ok, "<p>Hi</p>\n"} = Lettermint.Messages.source(client, "m")
      assert {:ok, "<p>Hi</p>\n"} = Lettermint.Messages.text(client, "m")
      assert {:ok, "pong"} = Lettermint.ping(team_client(raw(200, " pong \n")))
    end

    test "an empty or invalid JSON body where JSON is expected is an UnexpectedResponseError" do
      assert {:error, %Lettermint.UnexpectedResponseError{status: 202, body_excerpt: ""} = error} =
               Lettermint.Emails.send(
                 sending_client(raw(202, "", [{"content-type", "application/json"}])),
                 %{}
               )

      assert error.message =~ "empty body where JSON was expected"

      assert {:error, %Lettermint.UnexpectedResponseError{status: 200}} =
               Lettermint.Team.retrieve(team_client(raw(200, "   ")))

      assert {:error, %Lettermint.UnexpectedResponseError{status: 200, body_excerpt: "{oops"}} =
               Lettermint.Team.retrieve(team_client(raw(200, "{oops")))

      long = String.duplicate("x", 500)

      assert {:error, %{body_excerpt: excerpt}} =
               Lettermint.Team.retrieve(team_client(raw(200, long)))

      assert excerpt == String.duplicate("x", 200) <> "…"
    end

    test "an HTML error page is an UnexpectedResponseError with the status" do
      page = "<html><body><h1>502 Bad Gateway</h1></body></html>"

      assert {:error, %Lettermint.UnexpectedResponseError{status: 502} = error} =
               Lettermint.Emails.send(
                 sending_client(raw(502, page, [{"content-type", "text/html; charset=UTF-8"}])),
                 %{}
               )

      assert error.message ==
               "The Lettermint API answered with HTTP 502 and a body that is not JSON (text/html)."

      assert error.body_excerpt == page
    end

    test "maps error statuses to typed errors" do
      body = %{error: %{code: "domain_not_found", message: "Not here", details: %{id: "d"}}}

      for {status, module} <- [
            {400, Lettermint.APIError},
            {401, Lettermint.AuthenticationError},
            {403, Lettermint.PermissionError},
            {404, Lettermint.NotFoundError},
            {409, Lettermint.ConflictError},
            {418, Lettermint.APIError},
            {500, Lettermint.ServerError},
            {503, Lettermint.ServerError}
          ] do
        assert {:error, %^module{} = error} =
                 Lettermint.Domains.retrieve(team_client(json(status, body)), "d")

        assert error.status == status
        assert error.code == "domain_not_found"
        assert error.message == "Not here"
        assert Exception.message(error) == "Not here"
        assert error.details == %{"id" => "d"}

        assert error.body == %{
                 "error" => %{
                   "code" => "domain_not_found",
                   "details" => %{"id" => "d"},
                   "message" => "Not here"
                 }
               }

        assert Lettermint.Error.is_api_error(error)
      end
    end

    test "reads Laravel validation errors, string error codes and empty bodies" do
      laravel = %{
        message: "The to field is required.",
        errors: %{to: ["The to field is required."]}
      }

      assert {:error,
              %Lettermint.ValidationError{
                status: 422,
                code: nil,
                message: "The to field is required.",
                errors: %{"to" => ["The to field is required."]}
              }} =
               Lettermint.Emails.send(sending_client(json(422, laravel)), %{})

      assert {:error, %Lettermint.APIError{status: 400, code: "invalid_request", message: "Bad"}} =
               Lettermint.Team.retrieve(
                 team_client(json(400, %{error: "invalid_request", message: "Bad"}))
               )

      assert {:error, %Lettermint.ServerError{status: 500, message: "HTTP 500", body: nil}} =
               Lettermint.Team.retrieve(team_client(raw(500, "")))
    end

    test "429 carries Retry-After in seconds or from an HTTP date" do
      assert {:error, %Lettermint.RateLimitError{retry_after: 7}} =
               Lettermint.Team.retrieve(
                 team_client(json(429, %{message: "Too Many Requests"}, [{"retry-after", "7"}]))
               )

      date = DateTime.utc_now() |> DateTime.add(30, :second)
      http_date = Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S GMT")

      assert {:error, %{retry_after: seconds}} =
               Lettermint.Team.retrieve(team_client(json(429, %{}, [{"Retry-After", http_date}])))

      assert seconds in 29..31

      assert {:error, %{retry_after: nil}} = Lettermint.Team.retrieve(team_client(json(429, %{})))

      assert {:error, %{retry_after: nil}} =
               Lettermint.Team.retrieve(team_client(json(429, %{}, [{"retry-after", "soon"}])))

      assert Lettermint.Transport.retry_after("Sun, 06 Nov 1994 08:49:37 GMT") == 0
    end

    test "a 5xx carries Retry-After when the API sent it" do
      unavailable = json(503, %{message: "Service Unavailable"}, [{"retry-after", "2"}])

      assert {:error, %Lettermint.ServerError{status: 503, retry_after: 2}} =
               Lettermint.Team.retrieve(team_client(unavailable))

      assert {:error, %Lettermint.ServerError{status: 500, retry_after: nil}} =
               Lettermint.Team.retrieve(team_client(json(500, %{message: "Server Error"})))
    end

    test "a 3xx is a RedirectError and is never followed" do
      client = sending_client(raw(307, "", [{"location", "https://evil.example/v1/send"}]))

      assert {:error, %Lettermint.RedirectError{status: 307} = error} =
               Lettermint.Emails.send(client, %{})

      assert Exception.message(error) =~ "Redirects are not followed"
      assert_receive {:request, _}
      refute_receive {:request, _}, 50
    end

    test "tokens are redacted from error bodies" do
      echo = json(401, %{message: "Token #{team_token()} is revoked", token: team_token()})
      assert {:error, error} = Lettermint.Team.retrieve(team_client(echo))
      assert error.message == "Token [redacted] is revoked"
      assert error.body["token"] == "[redacted]"

      assert {:error, error} =
               Lettermint.Team.retrieve(team_client(raw(502, "bad #{team_token()}")))

      refute error.body_excerpt =~ team_token()
    end

    test "unknown enum values and fields decode; nil and :unset stay apart" do
      client =
        sending_client(
          json(202, %{
            message_id: "m",
            status: "some_future_status",
            scheduled_at: nil,
            new_field: [1]
          })
        )

      assert {:ok, response} = Lettermint.Emails.send(client, %{})
      assert response.status == "some_future_status"
      assert response.scheduled_at == nil
      assert response.sandbox == :unset
      assert response.extra == %{"new_field" => [1]}

      assert Types.to_map(response) == %{
               "message_id" => "m",
               "status" => "some_future_status",
               "scheduled_at" => nil,
               "new_field" => [1]
             }
    end
  end

  describe "transport failures" do
    defmodule FailingAdapter do
      @behaviour Lettermint.Adapter
      @impl true
      def request(_request, mode: :refused),
        do: {:error, %Req.TransportError{reason: :econnrefused}}

      def request(_request, mode: :timeout_reason),
        do: {:error, %Req.TransportError{reason: :timeout}}

      def request(_request, mode: :raise), do: raise("adapter bug")
      def request(_request, mode: :exit), do: exit(:pool_down)
      def request(_request, mode: :garbage), do: :nope

      def request(request, mode: :slow) do
        Process.sleep(request.timeout + 500)
        {:ok, %{status: 200, headers: [], body: "{}"}}
      end
    end

    defp failing(mode, options \\ []),
      do:
        Lettermint.new(
          [team_token: team_token(), adapter: {FailingAdapter, mode: mode}] ++ options
        )

    test "connection errors keep their reason" do
      assert {:error,
              %Lettermint.ConnectionError{reason: %Req.TransportError{reason: :econnrefused}} =
                error} =
               Lettermint.Team.retrieve(failing(:refused))

      assert Exception.message(error) == "Could not reach the Lettermint API: connection refused"

      assert {:error, %Lettermint.ConnectionError{reason: %RuntimeError{message: "adapter bug"}}} =
               Lettermint.Team.retrieve(failing(:raise))

      assert {:error, %Lettermint.ConnectionError{reason: {:exit, :pool_down}}} =
               Lettermint.Team.retrieve(failing(:exit))

      assert {:error, %Lettermint.ConnectionError{reason: {:invalid_adapter_response, :nope}}} =
               Lettermint.Team.retrieve(failing(:garbage))
    end

    test "the timeout covers the whole call and can be set per call" do
      started = System.monotonic_time(:millisecond)

      assert {:error, %Lettermint.TimeoutError{timeout: 100} = error} =
               Lettermint.Team.retrieve(failing(:slow, timeout: 100))

      assert System.monotonic_time(:millisecond) - started < 400

      assert Exception.message(error) ==
               "The request to the Lettermint API timed out after 100 ms."

      assert {:error, %Lettermint.TimeoutError{timeout: 50}} =
               Lettermint.Team.retrieve(failing(:slow), %{}, timeout: 50)

      assert {:error, %Lettermint.TimeoutError{}} =
               Lettermint.Team.retrieve(failing(:timeout_reason))

      assert_raise Lettermint.ConfigError, fn ->
        Lettermint.Team.retrieve(failing(:slow), %{}, timeout: 0)
      end
    end
  end

  describe "requests" do
    test "path parameters are encoded; empty, . and .. are rejected before any request" do
      client = team_client()
      Lettermint.Domains.verify_dns_record(client, "a/b c", "ü?#")
      assert_receive {:request, request}

      assert request.url ==
               "https://api.lettermint.co/v1/domains/a%2Fb%20c/dns-records/%C3%BC%3F%23/verify"

      for id <- ["", ".", "..", nil, 42] do
        assert_raise Lettermint.ConfigError,
                     ~r/domains.retrieve: domainId must be a non-empty string/,
                     fn ->
                       Lettermint.Domains.retrieve(client, id)
                     end
      end

      assert_raise Lettermint.ConfigError, ~r/webhooks.deliveries.retrieve: deliveryId/, fn ->
        Lettermint.Webhooks.Deliveries.retrieve(client, "w", "..")
      end

      refute_received {:request, _}
    end

    test "queries are serialized like the Node SDK" do
      client = team_client(json(200, %{data: [], next_cursor: nil}))

      Lettermint.Domains.list(client, %{
        page: %{size: 30},
        filter: %{status: "verified"},
        sort: ["-created_at", "domain"]
      })

      assert_receive {:request, request}

      assert query(request) ==
               "filter%5Bstatus%5D=verified&page%5Bsize%5D=30&sort=-created_at%2Cdomain"

      Lettermint.Messages.list(client, %{
        filter: %{tags: [%{name: "a", value: "b"}, %{name: "c d", value: "é"}], overdue: true}
      })

      assert_receive {:request, request}

      assert URI.decode_query(query(request)) == %{
               "filter[overdue]" => "1",
               "filter[tags][0][name]" => "a",
               "filter[tags][0][value]" => "b",
               "filter[tags][1][name]" => "c d",
               "filter[tags][1][value]" => "é"
             }

      assert query(request) =~ "c+d"
      assert query(request) =~ "%C3%A9"

      Lettermint.Stats.retrieve(client, %{
        "from" => ~D[2026-10-01],
        "to" => "2026-10-31",
        "project_id" => nil,
        "include_machine" => false
      })

      assert_receive {:request, request}
      assert query(request) == "from=2026-10-01&include_machine=0&to=2026-10-31"

      Lettermint.Webhooks.list(client, %{cursor: "abc", page: [size: 5], sort: []})
      assert_receive {:request, request}
      assert query(request) == "cursor=abc&page%5Bsize%5D=5"

      Lettermint.Domains.list(client)
      assert_receive {:request, request}
      assert request.url == "https://api.lettermint.co/v1/domains"
    end

    test "Lettermint.Query matches URLSearchParams" do
      assert Lettermint.Query.encode(%{"a*b-c._~" => "x y!'()"}) == "a*b-c._%7E=x+y%21%27%28%29"

      assert Lettermint.Query.encode(b: 1, a: 2.5, c: :atom, d: [nil, 1, true]) ==
               "b=1&a=2.5&c=atom&d=1%2C1"

      assert Lettermint.Query.encode(%{t: ~U[2026-10-04 09:00:00Z]}) ==
               "t=2026-10-04T09%3A00%3A00Z"

      assert Lettermint.Query.encode(%{list: [[a: 1], [a: 2]]}) ==
               "list%5B0%5D%5Ba%5D=1&list%5B1%5D%5Ba%5D=2"

      assert Lettermint.Query.encode(nil) == ""
      assert_raise Lettermint.ConfigError, fn -> Lettermint.Query.encode(%{a: {1, 2}}) end
    end

    test "the query must be a map, so options are not mistaken for it" do
      assert_raise Lettermint.ConfigError, ~r/domains.list: the query must be a map/, fn ->
        Lettermint.Domains.list(team_client(), timeout: 1000)
      end

      assert_raise Lettermint.ConfigError, ~r/unknown option :idempotency_key/, fn ->
        Lettermint.Domains.list(team_client(), %{}, idempotency_key: "k")
      end
    end

    test "request bodies take structs or maps" do
      client = team_client(json(201, %{id: "d", domain: "acme.com"}))

      assert {:ok, %Types.DomainData{id: "d", domain: "acme.com"}} =
               Lettermint.Domains.create(client, %Types.StoreDomainData{domain: "acme.com"})

      assert_receive {:request, request}
      assert Jason.decode!(request.body) == %{"domain" => "acme.com"}
      assert header(request, "content-type") == "application/json"

      assert {:ok, _} = Lettermint.Domains.update_projects(client, "d", %{project_ids: ["p"]})
      assert_receive {:request, request}
      assert request.method == :put
      assert Jason.decode!(request.body) == %{"project_ids" => ["p"]}
    end

    test "messages.process takes an idempotency key" do
      client = team_client(json(200, %{}))
      Lettermint.Messages.process(client, "m", idempotency_key: "p-1")
      assert_receive {:request, request}
      assert header(request, "idempotency-key") == "p-1"
      assert request.body == nil
    end
  end

  describe "pagination" do
    defp pages(pages) do
      fn request ->
        params = URI.decode_query(query(request) || "")
        cursor = params["page[cursor]"] || params["cursor"] || "first"
        json(200, Map.fetch!(pages, cursor))
      end
    end

    test "list/3 returns a CursorPage" do
      client =
        team_client(
          json(200, %{
            data: [%{id: "d1", domain: "a.co"}],
            path: "/v1/domains",
            per_page: 1,
            next_cursor: "c2",
            next_page_url: nil,
            prev_cursor: nil,
            prev_page_url: nil
          })
        )

      assert {:ok,
              %Types.CursorPage{
                data: [%Types.DomainListData{id: "d1"}],
                next_cursor: "c2",
                per_page: 1
              }} = Lettermint.Domains.list(client)
    end

    test "iterate/3 streams every item lazily, following next_cursor" do
      client =
        team_client(
          pages(%{
            "first" => %{data: [%{id: "1"}, %{id: "2"}], next_cursor: "c2"},
            "c2" => %{data: [%{id: "3"}], next_cursor: "c3"},
            "c3" => %{data: [%{id: "4"}], next_cursor: nil}
          })
        )

      stream =
        Lettermint.Domains.iterate(client, %{page: %{size: 2}, filter: %{status: "verified"}})

      refute_received {:request, _}
      assert Enum.map(stream, & &1.id) == ["1", "2", "3", "4"]

      assert_receive {:request, first}

      assert URI.decode_query(query(first)) == %{
               "page[size]" => "2",
               "filter[status]" => "verified"
             }

      assert_receive {:request, second}

      assert URI.decode_query(query(second)) == %{
               "page[size]" => "2",
               "page[cursor]" => "c2",
               "filter[status]" => "verified"
             }

      assert_receive {:request, _}
      refute_received {:request, _}

      # Taking fewer items requests fewer pages.
      assert stream |> Enum.take(2) |> length() == 2
      assert_receive {:request, _}
      refute_received {:request, _}
    end

    test "uses the cursor parameter of the operation and stops on a repeated cursor" do
      client =
        team_client(
          pages(%{
            "first" => %{data: [%{id: "w1"}], next_cursor: "a"},
            "a" => %{data: [%{id: "w2"}], next_cursor: "a"}
          })
        )

      assert Enum.map(Lettermint.Webhooks.iterate(client), & &1.id) == ["w1", "w2"]
      assert_receive {:request, _}
      assert_receive {:request, second}
      assert query(second) == "cursor=a"

      client =
        team_client(
          pages(%{
            "first" => %{data: [%{message_id: "e1"}], next_cursor: "x"},
            "x" => %{data: [], next_cursor: ""}
          })
        )

      assert Enum.map(Lettermint.Messages.iterate_events(client, "m"), & &1.message_id) == ["e1"]
      assert_receive {:request, request}
      assert path(request) == "/v1/messages/m/events"
    end

    test "raises the error of a failed page and checks the configuration eagerly" do
      client = team_client(json(500, %{message: "boom"}))

      assert_raise Lettermint.ServerError, "boom", fn ->
        Enum.to_list(Lettermint.Suppressions.iterate(client))
      end

      assert_raise Lettermint.ConfigError, fn ->
        Lettermint.Routes.iterate(sending_client(), "p")
      end

      assert_raise Lettermint.ConfigError, fn -> Lettermint.Routes.iterate(team_client(), "") end

      assert_raise Lettermint.UnexpectedResponseError, fn ->
        Enum.to_list(Lettermint.Team.Members.iterate(team_client(json(200, %{items: []}))))
      end
    end
  end
end

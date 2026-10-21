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

    test "messages.resend posts the optional recipients and an idempotency key" do
      client = team_client(json(202, %{message_id: "m2", status: "pending", future: 1}))

      assert {:ok,
              %Types.PendingSendMailResponse{
                message_id: "m2",
                status: "pending",
                extra: %{"future" => 1}
              }} = Lettermint.Messages.resend(client, "m 1")

      assert_receive {:request, request}
      assert request.method == :post
      assert path(request) == "/v1/messages/m%201/resend"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert header(request, "content-type") == "application/json"
      assert header(request, "idempotency-key") == nil
      assert Jason.decode!(request.body) == %{}

      assert {:ok, %Types.PendingSendMailResponse{}} =
               Lettermint.Messages.resend(
                 client,
                 "m",
                 %Types.ResendMessageRequest{recipients: ["jane@example.com"]},
                 idempotency_key: "r-1",
                 timeout: 5_000
               )

      assert_receive {:request, request}
      assert request.timeout == 5_000
      assert header(request, "idempotency-key") == "r-1"
      assert Jason.decode!(request.body) == %{"recipients" => ["jane@example.com"]}

      assert {:ok, _} =
               Lettermint.Messages.resend(client, "m", %{recipients: ["a@x.co", "b@x.co"]})

      assert_receive {:request, request}
      assert Jason.decode!(request.body) == %{"recipients" => ["a@x.co", "b@x.co"]}

      assert {:ok, _} = Lettermint.Messages.resend(client, "m", %Types.ResendMessageRequest{})
      assert_receive {:request, request}
      assert Jason.decode!(request.body) == %{}
    end

    test "messages.resend validates its arguments before sending" do
      assert_raise Lettermint.ConfigError, ~r/messages.resend: the body must be a map/, fn ->
        Lettermint.Messages.resend(team_client(), "m", idempotency_key: "k")
      end

      assert_raise Lettermint.ConfigError, ~r/messages.resend: messageId must be/, fn ->
        Lettermint.Messages.resend(team_client(), "")
      end

      assert {:error, %Lettermint.ClientValidationError{field: "idempotency_key"}} =
               Lettermint.Messages.resend(team_client(), "m", %{}, idempotency_key: "a\nb")

      refute_received {:request, _}
    end

    test "messages.resend maps 410 to an APIError" do
      body = %{error: %{code: "MESSAGE_CONTENT_UNAVAILABLE", message: "Gone", details: %{}}}

      assert {:error,
              %Lettermint.APIError{status: 410, code: "MESSAGE_CONTENT_UNAVAILABLE"} = error} =
               Lettermint.Messages.resend(team_client(json(410, body)), "m")

      assert error.message == "Gone"
      assert Lettermint.Error.is_api_error(error)
    end

    test "webhooks.deliveries.retry posts without a body and decodes the 202" do
      client = team_client(json(202, %{message: "Retry queued", delivery_id: "d 1", future: 1}))

      assert {:ok,
              %Types.RetryWebhookDeliveryResponse{
                message: "Retry queued",
                delivery_id: "d 1",
                extra: %{"future" => 1}
              }} = Lettermint.Webhooks.Deliveries.retry(client, "w 1", "d 1", timeout: 5_000)

      assert_receive {:request, request}
      assert request.method == :post
      assert path(request) == "/v1/webhooks/w%201/deliveries/d%201/retry"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert header(request, "x-lettermint-token") == nil
      assert header(request, "idempotency-key") == nil
      assert request.body == nil
      assert request.timeout == 5_000
    end

    test "webhooks.deliveries.retry validates its path parameters and needs the team token" do
      assert_raise Lettermint.ConfigError, ~r/webhooks.deliveries.retry: webhookId/, fn ->
        Lettermint.Webhooks.Deliveries.retry(team_client(), "", "d")
      end

      assert_raise Lettermint.ConfigError, ~r/webhooks.deliveries.retry: deliveryId/, fn ->
        Lettermint.Webhooks.Deliveries.retry(team_client(), "w", "..")
      end

      assert_raise Lettermint.ConfigError, ~r/webhooks.deliveries.retry needs :team_token/, fn ->
        Lettermint.Webhooks.Deliveries.retry(sending_client(), "w", "d")
      end

      refute_received {:request, _}
    end

    test "webhooks.deliveries.retry maps 409 to a ConflictError with the code" do
      body = %{
        error: %{
          code: "WEBHOOK_DELIVERY_NOT_RETRYABLE",
          message: "This delivery cannot be retried.",
          details: %{}
        }
      }

      assert {:error,
              %Lettermint.ConflictError{status: 409, code: "WEBHOOK_DELIVERY_NOT_RETRYABLE"} =
                error} =
               Lettermint.Webhooks.Deliveries.retry(team_client(json(409, body)), "w", "d")

      assert error.message == "This delivery cannot be retried."
      assert Lettermint.Error.is_api_error(error)
    end

    test "webhook deliveries decode next_retry_at as a value, nil or :unset" do
      delivery = %{id: "d", status: "failed", next_retry_at: "2026-10-18T12:00:00Z"}

      assert {:ok, %Types.WebhookDeliveryData{next_retry_at: "2026-10-18T12:00:00Z"}} =
               Lettermint.Webhooks.Deliveries.retrieve(team_client(json(200, delivery)), "w", "d")

      assert {:ok, %Types.WebhookDeliveryData{next_retry_at: nil}} =
               Lettermint.Webhooks.Deliveries.retrieve(
                 team_client(json(200, %{delivery | next_retry_at: nil})),
                 "w",
                 "d"
               )

      assert {:ok, %Types.WebhookDeliveryData{next_retry_at: :unset}} =
               Lettermint.Webhooks.Deliveries.retrieve(
                 team_client(json(200, Map.delete(delivery, :next_retry_at))),
                 "w",
                 "d"
               )

      page = %{data: [%{id: "d", next_retry_at: nil}], next_cursor: nil}

      assert {:ok, %{data: [%Types.WebhookDeliveryListData{next_retry_at: nil}]}} =
               Lettermint.Webhooks.Deliveries.list(team_client(json(200, page)), "w")
    end
  end

  describe "team invites" do
    defp invite(overrides \\ %{}) do
      Map.merge(
        %{
          id: "i 1",
          email: "jane@example.com",
          role: %{id: "r1", name: "Developer"},
          project_access: %{scope: "selected", projects: [%{id: "p1", name: "Production"}]},
          created_at: "2026-10-20T09:00:00Z"
        },
        overrides
      )
    end

    test "team.invites.create posts the invite and decodes the 201" do
      client = team_client(json(201, invite(%{future: 1})))

      assert {:ok,
              %Types.TeamInviteData{
                id: "i 1",
                email: "jane@example.com",
                role: %Types.TeamInviteDataRole{id: "r1", name: "Developer"},
                project_access: %Types.TeamMemberProjectAccessData{
                  scope: "selected",
                  projects: [%Types.TeamMemberProjectAccessDataProjectsItem{id: "p1"}]
                },
                created_at: "2026-10-20T09:00:00Z",
                extra: %{"future" => 1}
              }} =
               Lettermint.Team.Invites.create(
                 client,
                 %Types.CreateTeamInviteData{
                   email: "jane@example.com",
                   role_id: "r1",
                   project_access: %Types.CreateTeamInviteDataProjectAccess{
                     scope: "selected",
                     project_ids: ["p1"]
                   }
                 },
                 timeout: 5_000
               )

      assert_receive {:request, request}
      assert request.method == :post
      assert path(request) == "/v1/team/invites"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert header(request, "x-lettermint-token") == nil
      assert header(request, "idempotency-key") == nil
      assert header(request, "content-type") == "application/json"
      assert request.timeout == 5_000

      assert Jason.decode!(request.body) == %{
               "email" => "jane@example.com",
               "role_id" => "r1",
               "project_access" => %{"scope" => "selected", "project_ids" => ["p1"]}
             }

      assert {:ok, %Types.TeamInviteData{}} =
               Lettermint.Team.Invites.create(client, %{
                 email: "jane@example.com",
                 role_id: "r1",
                 project_access: %{scope: "all"}
               })

      assert_receive {:request, request}

      assert Jason.decode!(request.body) == %{
               "email" => "jane@example.com",
               "role_id" => "r1",
               "project_access" => %{"scope" => "all"}
             }
    end

    test "team.invites.update puts the replacement and decodes the invite" do
      client = team_client(json(200, invite(%{email: "john@example.com"})))

      assert {:ok, %Types.TeamInviteData{id: "i 1", email: "john@example.com"}} =
               Lettermint.Team.Invites.update(client, "i 1", %Types.UpdateTeamInviteData{
                 email: "john@example.com",
                 role_id: "r2",
                 project_access: %Types.UpdateTeamInviteDataProjectAccess{scope: "all"}
               })

      assert_receive {:request, request}
      assert request.method == :put
      assert path(request) == "/v1/team/invites/i%201"
      assert header(request, "authorization") == "Bearer " <> team_token()

      assert Jason.decode!(request.body) == %{
               "email" => "john@example.com",
               "role_id" => "r2",
               "project_access" => %{"scope" => "all"}
             }
    end

    test "team.invites list, retrieve and revoke" do
      client = team_client(json(200, %{data: [invite()], next_cursor: "c2"}))

      assert {:ok, %Types.CursorPage{data: [%Types.TeamInviteData{id: "i 1"}], next_cursor: "c2"}} =
               Lettermint.Team.Invites.list(client, %{page: %{size: 10, cursor: "c1"}})

      assert_receive {:request, request}
      assert request.method == :get
      assert path(request) == "/v1/team/invites"

      assert URI.decode_query(query(request)) == %{
               "page[size]" => "10",
               "page[cursor]" => "c1"
             }

      assert header(request, "authorization") == "Bearer " <> team_token()

      assert {:ok, %Types.TeamInviteData{id: "i 1", role: %Types.TeamInviteDataRole{}}} =
               Lettermint.Team.Invites.retrieve(team_client(json(200, invite())), "i 1")

      assert_receive {:request, request}
      assert request.method == :get
      assert path(request) == "/v1/team/invites/i%201"
      assert request.body == nil

      assert {:ok, %Types.MessageResponse{message: "Invite revoked."}} =
               Lettermint.Team.Invites.revoke(
                 team_client(json(200, %{message: "Invite revoked."})),
                 "i 1"
               )

      assert_receive {:request, request}
      assert request.method == :delete
      assert path(request) == "/v1/team/invites/i%201"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert request.body == nil
    end

    test "team.invites.iterate follows page[cursor]" do
      client =
        team_client(fn request ->
          case URI.decode_query(query(request) || "") do
            %{"page[cursor]" => "c2"} ->
              json(200, %{data: [invite(%{id: "i2"})], next_cursor: nil})

            _ ->
              json(200, %{data: [invite(%{id: "i1"})], next_cursor: "c2"})
          end
        end)

      assert Enum.map(Lettermint.Team.Invites.iterate(client, %{page: %{size: 1}}), & &1.id) ==
               ["i1", "i2"]

      assert_receive {:request, first}
      assert path(first) == "/v1/team/invites"
      assert URI.decode_query(query(first)) == %{"page[size]" => "1"}
      assert_receive {:request, second}
      assert URI.decode_query(query(second)) == %{"page[size]" => "1", "page[cursor]" => "c2"}
    end

    test "team.invites validates its path parameters and needs the team token" do
      assert_raise Lettermint.ConfigError, ~r/team.invites.retrieve: inviteId/, fn ->
        Lettermint.Team.Invites.retrieve(team_client(), "")
      end

      assert_raise Lettermint.ConfigError, ~r/team.invites.update: inviteId/, fn ->
        Lettermint.Team.Invites.update(team_client(), "..", %{})
      end

      assert_raise Lettermint.ConfigError, ~r/team.invites.revoke: inviteId/, fn ->
        Lettermint.Team.Invites.revoke(team_client(), ".")
      end

      assert_raise Lettermint.ConfigError, ~r/team.invites.create needs :team_token/, fn ->
        Lettermint.Team.Invites.create(sending_client(), %{})
      end

      assert_raise Lettermint.ConfigError, ~r/team.invites.list needs :team_token/, fn ->
        Lettermint.Team.Invites.list(sending_client())
      end

      refute_received {:request, _}
    end

    test "team.invites maps 409 to a ConflictError and 422 to a ValidationError" do
      conflict = %{
        error: %{code: "stale_resource", message: "The invite was changed in the meantime."}
      }

      assert {:error, %Lettermint.ConflictError{status: 409, code: "stale_resource"} = error} =
               Lettermint.Team.Invites.create(team_client(json(409, conflict)), %{})

      assert error.message == "The invite was changed in the meantime."
      assert Lettermint.Error.is_api_error(error)

      invalid = %{
        message: "The email field must be a valid email address.",
        errors: %{email: ["The email field must be a valid email address."]}
      }

      assert {:error,
              %Lettermint.ValidationError{
                status: 422,
                errors: %{"email" => ["The email field must be a valid email address."]}
              }} = Lettermint.Team.Invites.update(team_client(json(422, invalid)), "i", %{})
    end
  end

  describe "team roles" do
    defp role(overrides \\ %{}) do
      Map.merge(
        %{
          id: "r 1",
          name: "Support",
          description: "Handles support tickets",
          system_key: nil,
          permissions: ["members:read", "messages:read"],
          assignable: true
        },
        overrides
      )
    end

    test "team.create_role posts the role and decodes the 201 with its description" do
      client = team_client(json(201, role(%{future: 1})))

      assert {:ok,
              %Types.TeamRoleData{
                id: "r 1",
                name: "Support",
                description: "Handles support tickets",
                system_key: nil,
                permissions: ["members:read", "messages:read"],
                assignable: true,
                extra: %{"future" => 1}
              }} =
               Lettermint.Team.create_role(
                 client,
                 %Types.CreateTeamRoleData{
                   name: "Support",
                   description: "Handles support tickets",
                   permissions: ["members:read", "messages:read"]
                 },
                 timeout: 5_000
               )

      assert_receive {:request, request}
      assert request.method == :post
      assert path(request) == "/v1/team/roles"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert header(request, "x-lettermint-token") == nil
      assert header(request, "idempotency-key") == nil
      assert header(request, "content-type") == "application/json"
      assert request.timeout == 5_000

      assert Jason.decode!(request.body) == %{
               "name" => "Support",
               "description" => "Handles support tickets",
               "permissions" => ["members:read", "messages:read"]
             }

      assert {:ok, _} =
               Lettermint.Team.create_role(client, %Types.CreateTeamRoleData{
                 name: "Support",
                 permissions: ["members:read"]
               })

      assert_receive {:request, request}

      assert Jason.decode!(request.body) == %{
               "name" => "Support",
               "permissions" => ["members:read"]
             }

      assert {:ok, _} =
               Lettermint.Team.create_role(client, %{
                 name: "Support",
                 description: nil,
                 permissions: []
               })

      assert_receive {:request, request}

      assert Jason.decode!(request.body) == %{
               "name" => "Support",
               "description" => nil,
               "permissions" => []
             }
    end

    test "team.retrieve_role decodes description as a value, nil or :unset" do
      assert {:ok, %Types.TeamRoleData{id: "r 1", description: "Handles support tickets"}} =
               Lettermint.Team.retrieve_role(team_client(json(200, role())), "r 1")

      assert_receive {:request, request}
      assert request.method == :get
      assert path(request) == "/v1/team/roles/r%201"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert request.body == nil

      assert {:ok, %Types.TeamRoleData{description: nil, system_key: "admin"}} =
               Lettermint.Team.retrieve_role(
                 team_client(json(200, role(%{description: nil, system_key: "admin"}))),
                 "r"
               )

      assert {:ok, %Types.TeamRoleData{description: :unset}} =
               Lettermint.Team.retrieve_role(
                 team_client(json(200, Map.delete(role(), :description))),
                 "r"
               )

      assert {:ok, %Types.TeamRoleListResponse{data: [%Types.TeamRoleData{description: nil}]}} =
               Lettermint.Team.roles(team_client(json(200, %{data: [role(%{description: nil})]})))
    end

    test "team.update_role puts the replacement" do
      client = team_client(json(200, role(%{name: "Support desk"})))

      assert {:ok, %Types.TeamRoleData{name: "Support desk"}} =
               Lettermint.Team.update_role(client, "r 1", %Types.UpdateTeamRoleData{
                 name: "Support desk",
                 description: nil,
                 permissions: ["members:read"]
               })

      assert_receive {:request, request}
      assert request.method == :put
      assert path(request) == "/v1/team/roles/r%201"
      assert header(request, "authorization") == "Bearer " <> team_token()

      assert Jason.decode!(request.body) == %{
               "name" => "Support desk",
               "description" => nil,
               "permissions" => ["members:read"]
             }
    end

    test "team.delete_role sends replacement_role_id only when given" do
      client = team_client(json(200, %{message: "Role deleted."}))

      assert {:ok, %Types.MessageResponse{message: "Role deleted."}} =
               Lettermint.Team.delete_role(client, "r 1")

      assert_receive {:request, request}
      assert request.method == :delete
      assert path(request) == "/v1/team/roles/r%201"
      assert query(request) == nil
      assert request.url == "https://api.lettermint.co/v1/team/roles/r%201"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert request.body == nil

      assert {:ok, %Types.MessageResponse{}} =
               Lettermint.Team.delete_role(client, "r 1", %{replacement_role_id: "r 2"},
                 timeout: 5_000
               )

      assert_receive {:request, request}
      assert path(request) == "/v1/team/roles/r%201"
      assert query(request) == "replacement_role_id=r+2"
      assert request.timeout == 5_000
      assert request.body == nil
    end

    test "team.duplicate_role posts the new name and the optional description" do
      client = team_client(json(201, role(%{id: "r 2", name: "Support copy"})))

      assert {:ok, %Types.TeamRoleData{id: "r 2", name: "Support copy"}} =
               Lettermint.Team.duplicate_role(client, "r 1", %Types.DuplicateTeamRoleData{
                 name: "Support copy"
               })

      assert_receive {:request, request}
      assert request.method == :post
      assert path(request) == "/v1/team/roles/r%201/duplicate"
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert Jason.decode!(request.body) == %{"name" => "Support copy"}

      assert {:ok, _} =
               Lettermint.Team.duplicate_role(client, "r 1", %{
                 name: "Support copy",
                 description: "A copy"
               })

      assert_receive {:request, request}
      assert Jason.decode!(request.body) == %{"name" => "Support copy", "description" => "A copy"}
    end

    test "team role functions validate their arguments and need the team token" do
      assert_raise Lettermint.ConfigError, ~r/team.retrieve_role: roleId/, fn ->
        Lettermint.Team.retrieve_role(team_client(), "")
      end

      assert_raise Lettermint.ConfigError, ~r/team.update_role: roleId/, fn ->
        Lettermint.Team.update_role(team_client(), "..", %{})
      end

      assert_raise Lettermint.ConfigError, ~r/team.delete_role: roleId/, fn ->
        Lettermint.Team.delete_role(team_client(), ".")
      end

      assert_raise Lettermint.ConfigError, ~r/team.duplicate_role: roleId/, fn ->
        Lettermint.Team.duplicate_role(team_client(), "", %{name: "R"})
      end

      assert_raise Lettermint.ConfigError, ~r/team.delete_role: the query must be a map/, fn ->
        Lettermint.Team.delete_role(team_client(), "r", timeout: 1000)
      end

      assert_raise Lettermint.ConfigError, ~r/team.create_role needs :team_token/, fn ->
        Lettermint.Team.create_role(sending_client(), %{})
      end

      refute_received {:request, _}
    end

    test "team role functions map 409 to a ConflictError with the code" do
      body = %{
        error: %{code: "built_in_role_immutable", message: "Built-in roles cannot be changed."}
      }

      assert {:error,
              %Lettermint.ConflictError{status: 409, code: "built_in_role_immutable"} = error} =
               Lettermint.Team.update_role(team_client(json(409, body)), "r", %{})

      assert error.message == "Built-in roles cannot be changed."
      assert Lettermint.Error.is_api_error(error)

      assert {:error, %Lettermint.ConflictError{status: 409}} =
               Lettermint.Team.delete_role(team_client(json(409, body)), "r")
    end
  end

  describe "team members" do
    test "team.members.remove deletes the member and decodes the message" do
      client = team_client(json(200, %{message: "Member removed.", future: 1}))

      assert {:ok, %Types.MessageResponse{message: "Member removed.", extra: %{"future" => 1}}} =
               Lettermint.Team.Members.remove(client, "u 1", timeout: 5_000)

      assert_receive {:request, request}
      assert request.method == :delete
      assert path(request) == "/v1/team/members/u%201"
      assert query(request) == nil
      assert header(request, "authorization") == "Bearer " <> team_token()
      assert header(request, "x-lettermint-token") == nil
      assert header(request, "idempotency-key") == nil
      assert request.body == nil
      assert request.timeout == 5_000
    end

    test "team.members.remove validates its path parameter and needs the team token" do
      for id <- ["", ".", ".."] do
        assert_raise Lettermint.ConfigError, ~r/team.members.remove: userId/, fn ->
          Lettermint.Team.Members.remove(team_client(), id)
        end
      end

      assert_raise Lettermint.ConfigError, ~r/team.members.remove needs :team_token/, fn ->
        Lettermint.Team.Members.remove(sending_client(), "u")
      end

      refute_received {:request, _}
    end

    test "team.members.remove maps 409 to a ConflictError and 404 to a NotFoundError" do
      body = %{error: %{code: "owner_protected", message: "The Owner cannot be removed."}}

      assert {:error, %Lettermint.ConflictError{status: 409, code: "owner_protected"} = error} =
               Lettermint.Team.Members.remove(team_client(json(409, body)), "u")

      assert error.message == "The Owner cannot be removed."
      assert Lettermint.Error.is_api_error(error)

      assert {:error, %Lettermint.NotFoundError{status: 404}} =
               Lettermint.Team.Members.remove(
                 team_client(json(404, %{message: "Not found."})),
                 "u"
               )
    end

    test "team.members.list and iterate send filter[project_id]" do
      member = %{id: "u1", name: "Jane", email: "jane@example.com"}
      client = team_client(json(200, %{data: [member], next_cursor: nil}))

      assert {:ok, %Types.CursorPage{data: [%Types.TeamMemberData{id: "u1"}]}} =
               Lettermint.Team.Members.list(client, %{filter: %{project_id: "p 1"}})

      assert_receive {:request, request}
      assert path(request) == "/v1/team/members"
      assert URI.decode_query(query(request)) == %{"filter[project_id]" => "p 1"}

      assert Enum.map(
               Lettermint.Team.Members.iterate(client, %{
                 page: %{size: 5},
                 filter: %{project_id: "p1"}
               }),
               & &1.id
             ) == ["u1"]

      assert_receive {:request, request}

      assert URI.decode_query(query(request)) == %{
               "filter[project_id]" => "p1",
               "page[size]" => "5"
             }

      assert {:ok, %Types.CursorPage{data: []}} =
               Lettermint.Team.Members.list(
                 team_client(json(200, %{data: [], next_cursor: nil})),
                 %{filter: %{project_id: "unknown"}}
               )
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

defmodule Lettermint.TeamAPITest do
  use ExUnit.Case, async: true
  import Lettermint.TestHelpers

  alias Lettermint.{
    Domains,
    Emails,
    Messages,
    Projects,
    Routes,
    Stats,
    Suppressions,
    Team,
    Webhooks
  }

  # Every operation of the generated table, with the public function that calls it.
  defp calls do
    [
      {"GET /ping", &Lettermint.ping(&1)},
      {"POST /analytics", &Lettermint.analytics(&1, %{metrics: ["sent"]})},
      {"GET /blocked-file-types", &Lettermint.blocked_file_types(&1)},
      {"POST /send", &Emails.send(&1, %{from: "a@x.co", to: ["b@x.co"], subject: "s"})},
      {"POST /send/batch",
       &Emails.send_batch(&1, [%{from: "a@x.co", to: ["b@x.co"], subject: "s"}])},
      {"GET /domains", &Domains.list(&1)},
      {"POST /domains", &Domains.create(&1, %{domain: "acme.com"})},
      {"GET /domains/{domainId}", &Domains.retrieve(&1, "id1")},
      {"DELETE /domains/{domainId}", &Domains.delete(&1, "id1")},
      {"POST /domains/{domainId}/dns-records/verify", &Domains.verify_dns_records(&1, "id1")},
      {"POST /domains/{domainId}/dns-records/{recordId}/verify",
       &Domains.verify_dns_record(&1, "id1", "id2")},
      {"PUT /domains/{domainId}/projects",
       &Domains.update_projects(&1, "id1", %{project_ids: []})},
      {"GET /messages", &Messages.list(&1)},
      {"GET /messages/{messageId}", &Messages.retrieve(&1, "id1")},
      {"GET /messages/{messageId}/events", &Messages.events(&1, "id1")},
      {"GET /messages/{messageId}/source", &Messages.source(&1, "id1")},
      {"GET /messages/{messageId}/html", &Messages.html(&1, "id1")},
      {"GET /messages/{messageId}/text", &Messages.text(&1, "id1")},
      {"PATCH /messages/{messageId}",
       &Messages.reschedule(&1, "id1", %{scheduled_at: "tomorrow"})},
      {"POST /messages/{messageId}/cancel", &Messages.cancel(&1, "id1")},
      {"POST /messages/{messageId}/process", &Messages.process(&1, "id1")},
      {"GET /projects", &Projects.list(&1)},
      {"POST /projects", &Projects.create(&1, %{name: "P"})},
      {"GET /projects/{projectId}", &Projects.retrieve(&1, "id1")},
      {"PUT /projects/{projectId}", &Projects.update(&1, "id1", %{name: "P"})},
      {"DELETE /projects/{projectId}", &Projects.delete(&1, "id1")},
      {"POST /projects/{projectId}/rotate-token", &Projects.rotate_token(&1, "id1")},
      {"GET /projects/{projectId}/report-forwarding",
       &Projects.ReportForwarding.retrieve(&1, "id1")},
      {"PUT /projects/{projectId}/report-forwarding",
       &Projects.ReportForwarding.update(&1, "id1", %{email: "a@x.co"})},
      {"DELETE /projects/{projectId}/report-forwarding",
       &Projects.ReportForwarding.delete(&1, "id1")},
      {"POST /projects/{projectId}/report-forwarding/verify",
       &Projects.ReportForwarding.verify(&1, "id1", %{code: "1"})},
      {"POST /projects/{projectId}/report-forwarding/resend-code",
       &Projects.ReportForwarding.resend_code(&1, "id1")},
      {"GET /projects/{projectId}/routes", &Routes.list(&1, "id1")},
      {"POST /projects/{projectId}/routes", &Routes.create(&1, "id1", %{name: "R"})},
      {"GET /routes/{routeId}", &Routes.retrieve(&1, "id1")},
      {"PUT /routes/{routeId}", &Routes.update(&1, "id1", %{name: "R"})},
      {"DELETE /routes/{routeId}", &Routes.delete(&1, "id1")},
      {"POST /routes/{routeId}/verify-inbound-domain", &Routes.verify_inbound_domain(&1, "id1")},
      {"GET /stats", &Stats.retrieve(&1, %{from: "2026-10-01", to: "2026-10-31"})},
      {"GET /suppressions", &Suppressions.list(&1)},
      {"POST /suppressions", &Suppressions.create(&1, %{value: "a@x.co"})},
      {"DELETE /suppressions/{suppressionId}", &Suppressions.delete(&1, "id1")},
      {"GET /team", &Team.retrieve(&1)},
      {"PUT /team", &Team.update(&1, %{name: "T"})},
      {"GET /team/usage", &Team.usage(&1)},
      {"GET /team/roles", &Team.roles(&1)},
      {"GET /team/members", &Team.Members.list(&1)},
      {"GET /team/members/{userId}", &Team.Members.retrieve(&1, "id1")},
      {"PUT /team/members/{userId}/assignment",
       &Team.Members.update_assignment(&1, "id1", %{role: "admin"})},
      {"GET /webhooks", &Webhooks.list(&1)},
      {"POST /webhooks", &Webhooks.create(&1, %{url: "https://x.co"})},
      {"GET /webhooks/{webhookId}", &Webhooks.retrieve(&1, "id1")},
      {"PUT /webhooks/{webhookId}", &Webhooks.update(&1, "id1", %{enabled: false})},
      {"DELETE /webhooks/{webhookId}", &Webhooks.delete(&1, "id1")},
      {"POST /webhooks/{webhookId}/test", &Webhooks.test(&1, "id1")},
      {"POST /webhooks/{webhookId}/regenerate-secret", &Webhooks.regenerate_secret(&1, "id1")},
      {"GET /webhooks/{webhookId}/deliveries", &Webhooks.Deliveries.list(&1, "id1")},
      {"GET /webhooks/{webhookId}/deliveries/{deliveryId}",
       &Webhooks.Deliveries.retrieve(&1, "id1", "id2")}
    ]
  end

  # The stream functions of every paginated operation.
  defp streams do
    [
      {"GET /domains", &Domains.iterate(&1)},
      {"GET /messages", &Messages.iterate(&1)},
      {"GET /messages/{messageId}/events", &Messages.iterate_events(&1, "id1")},
      {"GET /projects", &Projects.iterate(&1)},
      {"GET /projects/{projectId}/routes", &Routes.iterate(&1, "id1")},
      {"GET /suppressions", &Suppressions.iterate(&1)},
      {"GET /team/members", &Team.Members.iterate(&1)},
      {"GET /webhooks", &Webhooks.iterate(&1)},
      {"GET /webhooks/{webhookId}/deliveries", &Webhooks.Deliveries.iterate(&1, "id1")}
    ]
  end

  defp respond(request) do
    path = path(request)

    cond do
      path =~ ~r{/(source|html|text)$} or path == "/v1/ping" -> raw(200, "pong")
      path =~ ~r{/report-forwarding$} and request.method == :delete -> raw(204, "")
      path == "/v1/send/batch" -> json(202, [%{message_id: "m", status: "pending"}])
      true -> json(200, %{data: [], next_cursor: nil})
    end
  end

  defp expected_path(key) do
    [_method, template] = String.split(key, " ")

    "/v1" <>
      String.replace(template, ~r/\{(\w+)\}/, fn segment ->
        if segment =~ "deliveryId" or segment =~ "recordId", do: "id2", else: "id1"
      end)
  end

  test "every operation in the generated table is reachable through a public function" do
    assert Enum.sort(Enum.map(calls(), &elem(&1, 0))) == Lettermint.Operations.keys()

    for {key, call} <- calls() do
      operation = Lettermint.Operations.fetch!(key)
      client = client([], &respond/1)
      result = call.(client)
      assert match?({:ok, _}, result) or result == :ok, "#{key}: #{inspect(result)}"
      assert_receive {:request, request}
      assert request.method == operation.method, key
      assert path(request) == expected_path(key), key

      case operation.auth do
        :sending -> assert header(request, "x-lettermint-token") == sending_token(), key
        _ -> assert header(request, "authorization") == "Bearer " <> team_token(), key
      end
    end
  end

  test "every paginated operation has a stream" do
    paginated = for {key, %{pagination: %{}}} <- Lettermint.Operations.all(), do: key
    assert Enum.sort(Enum.map(streams(), &elem(&1, 0))) == Enum.sort(paginated)

    for {key, stream} <- streams() do
      assert stream.(team_client(&respond/1)) |> Enum.to_list() == []
      assert_receive {:request, request}
      assert path(request) == expected_path(key)
    end
  end

  test "the sending-only and team-only operations match the table" do
    sending = for {key, %{auth: :sending}} <- Lettermint.Operations.all(), do: key
    either = for {key, %{auth: :either}} <- Lettermint.Operations.all(), do: key
    assert Enum.sort(sending) == ["POST /send", "POST /send/batch"]

    assert Enum.sort(either) == [
             "GET /ping",
             "PATCH /messages/{messageId}",
             "POST /messages/{messageId}/cancel"
           ]
  end

  test "typed responses decode into the generated structs" do
    client =
      team_client(
        json(200, %{
          id: "p",
          name: "Production",
          delivery_mode: "sandbox",
          routes: [%{id: "r", slug: "outgoing", future: true}]
        })
      )

    assert {:ok, %Lettermint.Types.ProjectData{id: "p", delivery_mode: "sandbox"} = project} =
             Projects.retrieve(client, "p")

    assert [%Lettermint.Types.RouteData{id: "r", slug: "outgoing", extra: %{"future" => true}}] =
             project.routes

    assert project.domains == :unset
    assert project.extra == %{}
  end
end

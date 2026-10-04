defmodule Lettermint.TypesTest do
  use ExUnit.Case, async: true

  alias Lettermint.Types

  doctest Lettermint.Query
  doctest Lettermint.Types

  test "decoding keeps unknown fields, unknown enum values and values of an unexpected type" do
    decoded =
      Types.decode(
        %{
          "id" => "d",
          "dns_records" => [%{"id" => "r", "status" => "brand_new_status", "type" => 42}],
          "projects" => "not a list",
          "brand_new" => %{"nested" => true}
        },
        Types.DomainData
      )

    assert %Types.DomainData{
             id: "d",
             projects: "not a list",
             extra: %{"brand_new" => %{"nested" => true}}
           } = decoded

    assert [%Types.DomainDnsRecordData{status: "brand_new_status", type: 42}] =
             decoded.dns_records

    assert decoded.created_at == :unset
  end

  test "an empty PHP array decodes as an empty map or struct" do
    assert %Types.AnalyticsBreakdownRow{dimensions: %{}} =
             Types.decode(%{"dimensions" => []}, Types.AnalyticsBreakdownRow)

    assert %Types.ApiErrorDetail{} = Types.decode([], Types.ApiErrorDetail)
  end

  test "unions, lists and pages" do
    assert Types.decode("tag:campaign", Types.AnalyticsDimension) == "tag:campaign"

    assert [%Types.SendMailResponse{status: "pending"}] =
             Types.decode([%{"status" => "pending"}], Types.SendBatchMailResponse)

    assert %Types.CursorPage{
             data: [%Types.WebhookListData{id: "w"}],
             next_cursor: nil,
             extra: %{"links" => []}
           } =
             Types.decode(
               %{"data" => [%{"id" => "w"}], "next_cursor" => nil, "links" => []},
               Types.ListWebhooksResponse
             )

    assert %Types.ErrorMessage{message: "slow down"} =
             Types.decode(%{"message" => "slow down"}, Types.TooManyRequests)
  end

  test "to_map/1 is the inverse of decode/2 and keeps nil apart from :unset" do
    json = %{
      "id" => "p",
      "name" => "P",
      "default_route_id" => nil,
      "routes" => [%{"id" => "r", "new" => 1}],
      "future" => "x"
    }

    project = Types.decode(json, Types.ProjectData)
    assert Types.to_map(project) == json

    assert Types.to_map(%{
             at: ~U[2026-10-04 09:00:00Z],
             status: :delivered,
             ok: true,
             none: nil,
             list: [%Types.MessageTagInput{name: "a", value: "b"}]
           }) ==
             %{
               "at" => "2026-10-04T09:00:00Z",
               "status" => "delivered",
               "ok" => true,
               "none" => nil,
               "list" => [%{"name" => "a", "value" => "b"}]
             }
  end

  test "enum modules list the known values" do
    assert "hard_bounced" in Types.SandboxResult.values()
    assert "message.delivered" in Types.WebhookEvent.values()
    assert Types.DeliveryMode.values() == ["live", "sandbox"]
  end

  test "killing the calling process cancels the request" do
    test = self()

    defmodule SlowAdapter do
      @behaviour Lettermint.Adapter
      @impl true
      def request(_request, test: test) do
        send(test, {:started, self()})
        Process.sleep(2_000)
        send(test, :finished)
        {:ok, %{status: 200, headers: [], body: "{}"}}
      end
    end

    client =
      Lettermint.new(
        team_token: Lettermint.TestHelpers.team_token(),
        adapter: {SlowAdapter, test: test}
      )

    caller = Task.async(fn -> Lettermint.Team.retrieve(client) end)
    assert_receive {:started, request_process}, 1_000
    ref = Process.monitor(request_process)
    Task.shutdown(caller, :brutal_kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    refute_receive :finished, 100
  end
end

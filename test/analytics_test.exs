defmodule Lettermint.AnalyticsTest do
  use ExUnit.Case, async: true
  import Lettermint.TestHelpers

  alias Lettermint.Types

  @page_one "test/fixtures/analytics-page-1.json" |> File.read!() |> Jason.decode!()
  @page_two "test/fixtures/analytics-page-2.json" |> File.read!() |> Jason.decode!()
  @summary_only "test/fixtures/analytics-summary.json" |> File.read!() |> Jason.decode!()

  @query %{
    metrics: ["delivered", "bounced", "delivery_rate", "delivery_latency_p50_ms"],
    include: ["summary", "time_series", "breakdown"],
    group_by: ["recipient_domain"],
    interval: "hour",
    timezone: "Asia/Kolkata",
    compare: "previous_period",
    limit: 2
  }

  # The requests made so far, oldest first.
  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  defp body(request), do: Jason.decode!(request.body)

  # Answers the first page, then `next` for a request with a cursor.
  defp pages(next) do
    fn request -> if body(request)["cursor"], do: next, else: json(200, @page_one) end
  end

  describe "analytics responses" do
    test "keeps null values, empty rate bases and both timestamp formats" do
      assert {:ok, %Types.AnalyticsResponse{} = result} =
               Lettermint.analytics(team_client(json(200, @page_one)), @query)

      assert [request] = requests()
      assert body(request) == Types.to_map(@query)
      assert Types.to_map(result) == @page_one

      summary = result.data.summary

      assert Types.to_map(summary.metrics) == %{
               "delivered" => 1200,
               "bounced" => 0,
               "delivery_rate" => 0.9836,
               "delivery_latency_p50_ms" => nil
             }

      assert summary.metrics.delivery_latency_p50_ms == nil
      assert summary.metrics.accepted == :unset

      assert %Types.AnalyticsRateBase{numerator: 1200, denominator: 1220} =
               summary.rate_bases.delivery_rate

      assert %Types.AnalyticsRateBase{numerator: nil, denominator: nil} =
               summary.previous.rate_bases.delivery_rate

      assert %Types.AnalyticsMetricChange{absolute: nil, relative: nil, percentage_points: nil} =
               summary.change["delivery_rate"]

      assert summary.change["delivered"].percentage_points == :unset

      assert [complete, unavailable] = result.data.time_series
      assert complete.from == "2026-09-15T08:30:00+05:30"
      assert {:ok, ~U[2026-09-15 03:00:00Z], 19_800} = DateTime.from_iso8601(complete.from)

      assert %Types.AnalyticsTimeSeriesPoint{available: false, partial: true} = unavailable
      assert unavailable.rate_bases == %Types.AnalyticsRateBases{}
      assert Types.to_map(unavailable.rate_bases) == %{}
      assert unavailable.metrics.delivered == nil

      assert result.meta.generated_at == "2026-09-15T04:12:30.482915Z"

      assert {:ok, ~U[2026-09-15 04:12:30.482915Z], 0} =
               DateTime.from_iso8601(result.meta.generated_at)

      assert {:ok, from, 0} = DateTime.from_iso8601(result.meta.from)
      assert DateTime.compare(from, ~U[2026-09-15 03:00:00Z]) == :eq
      assert result.meta.last_ingested_at == nil

      assert Types.to_map(result.meta.comparison) == %{
               "from" => "2026-09-15T01:00:00.000000Z",
               "to" => "2026-09-15T03:00:00.000000Z",
               "partial" => false
             }

      assert result.pagination == %Types.AnalyticsPagination{
               total_groups: 3,
               returned_groups: 2,
               next_cursor: "cursor-page-2",
               truncated: false
             }
    end

    test "leaves out the sections and comparison a query did not ask for" do
      assert {:ok, result} =
               Lettermint.analytics(team_client(json(200, @summary_only)), %{
                 metrics: ["delivered"]
               })

      assert result.data.summary.rate_bases == %Types.AnalyticsRateBases{}
      assert result.data.time_series == :unset
      assert result.data.breakdown == :unset
      assert result.data.summary.previous == :unset
      assert result.meta.comparison == :unset
      assert result.pagination.next_cursor == nil
      assert Types.to_map(result) == @summary_only
    end

    test "keeps a null dimension value in a breakdown row" do
      assert {:ok, result} =
               Lettermint.analytics(
                 team_client(json(200, @page_two)),
                 Map.put(@query, :cursor, "cursor-page-2")
               )

      assert [%Types.AnalyticsBreakdownRow{} = row] = result.data.breakdown
      assert row.dimensions == %{"recipient_domain" => nil}
      assert row.metrics.bounced == nil
    end
  end

  describe "analytics_pages/3" do
    test "follows next_cursor and streams every response" do
      stream = Lettermint.analytics_pages(team_client(pages(json(200, @page_two))), @query)
      assert [first, second] = Enum.to_list(stream)

      assert [first_request, second_request] = requests()

      for request <- [first_request, second_request] do
        assert request.method == :post
        assert path(request) == "/v1/analytics"
        assert header(request, "authorization") == "Bearer " <> team_token()
      end

      assert body(first_request) == Types.to_map(@query)
      assert body(second_request) == Map.put(Types.to_map(@query), "cursor", "cursor-page-2")

      rows = first.data.breakdown ++ second.data.breakdown

      assert Enum.map(rows, & &1.dimensions["recipient_domain"]) == [
               "gmail.com",
               "outlook.com",
               nil
             ]

      assert %Types.AnalyticsPagination{returned_groups: 1, next_cursor: nil} = second.pagination
    end

    test "takes a struct or a map with string keys" do
      client = team_client(pages(json(200, @page_two)))
      struct = %Types.AnalyticsQuery{metrics: ["delivered"], include: ["breakdown"], limit: 2}
      wire = %{"metrics" => ["delivered"], "include" => ["breakdown"], "limit" => 2}

      for query <- [struct, wire] do
        assert [_, _] = client |> Lettermint.analytics_pages(query) |> Enum.to_list()
        assert [first, second] = requests()
        assert body(first) == wire
        assert body(second) == Map.put(wire, "cursor", "cursor-page-2")
      end

      assert struct.cursor == :unset
    end

    test "makes one request for a query without more pages" do
      client = team_client(json(200, @summary_only))

      assert [%Types.AnalyticsResponse{}] =
               client |> Lettermint.analytics_pages(%{metrics: ["delivered"]}) |> Enum.to_list()

      assert [_] = requests()
    end

    test "requests the next page only when it is asked for" do
      stream = Lettermint.analytics_pages(team_client(json(200, @page_one)), @query)
      assert requests() == []

      assert [page] = Enum.take(stream, 1)
      assert page.pagination.next_cursor == "cursor-page-2"
      assert [_] = requests()
    end

    test "stops when the API repeats a cursor" do
      stream = Lettermint.analytics_pages(team_client(json(200, @page_one)), @query)
      assert [_, _] = Enum.to_list(stream)
      assert [_, _] = requests()
    end

    test "stops when the API returns the cursor the query started from" do
      for query <- [
            Map.put(@query, :cursor, "cursor-page-2"),
            %{"metrics" => ["delivered"], "cursor" => "cursor-page-2"},
            %Types.AnalyticsQuery{metrics: ["delivered"], cursor: "cursor-page-2"}
          ] do
        stream = Lettermint.analytics_pages(team_client(json(200, @page_one)), query)
        assert [_] = Enum.to_list(stream)
        assert [request] = requests()
        assert body(request) == Types.to_map(query)
      end
    end

    test "passes the options to every page and raises for an expired cursor" do
      expired = %{
        "message" => "The analytics cursor is invalid or expired. Submit a new query.",
        "errors" => %{
          "cursor" => ["The analytics cursor is invalid or expired. Submit a new query."]
        }
      }

      test = self()

      stream =
        team_client(pages(json(422, expired)))
        |> Lettermint.analytics_pages(@query, timeout: 1234)
        |> Stream.each(&send(test, {:page, &1}))

      error = assert_raise Lettermint.ValidationError, fn -> Stream.run(stream) end
      assert error.errors == expired["errors"]
      assert_received {:page, %Types.AnalyticsResponse{}}
      refute_received {:page, _}

      assert [first, second] = requests()
      assert first.timeout == 1234
      assert second.timeout == 1234
    end

    test "checks the configuration before any request" do
      assert_raise Lettermint.ConfigError, ~r/analytics_pages needs :team_token/, fn ->
        Lettermint.analytics_pages(sending_client(), @query)
      end

      assert_raise Lettermint.ConfigError, ~r/analytics_pages: unknown option :signal/, fn ->
        Lettermint.analytics_pages(team_client(), @query, signal: 1)
      end

      # apply/3, because the compiler warns about a query that is not a map.
      assert_raise Lettermint.ConfigError, ~r/analytics_pages: the query must be a map/, fn ->
        apply(Lettermint, :analytics_pages, [team_client(), [timeout: 1234]])
      end

      assert requests() == []
    end
  end

  describe "analytics errors" do
    test "reads field errors from a 422" do
      message = "smtp_response_group can only be used in group_by."
      client = team_client(json(422, %{message: message, errors: %{filters: [message]}}))

      assert {:error,
              %Lettermint.ValidationError{
                status: 422,
                message: ^message,
                errors: %{"filters" => [^message]}
              }} = Lettermint.analytics(client, @query)
    end

    test "reads Retry-After from a 503" do
      body = %{error: %{code: "SERVICE_UNAVAILABLE", message: "Try again shortly."}}
      client = team_client(json(503, body, [{"Retry-After", "2"}]))

      assert {:error,
              %Lettermint.ServerError{status: 503, code: "SERVICE_UNAVAILABLE", retry_after: 2}} =
               Lettermint.analytics(client, @query)
    end

    test "has no retry_after for a 503 or 504 without the header" do
      unavailable = team_client(json(503, %{message: "Analytics is unavailable."}))

      assert {:error, %Lettermint.ServerError{status: 503, retry_after: nil}} =
               Lettermint.analytics(unavailable, @query)

      message =
        "Analytics exceeded the query time limit. Retry with a shorter period or fewer dimensions."

      timed_out = team_client(json(504, %{message: message}))

      assert {:error, %Lettermint.ServerError{status: 504, message: ^message, retry_after: nil}} =
               Lettermint.analytics(timed_out, @query)
    end
  end
end

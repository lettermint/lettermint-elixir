defmodule Lettermint.ContractTest do
  use ExUnit.Case, async: true
  alias Lettermint.Model
  @fixtures Jason.decode!(File.read!(Path.join(__DIR__, "fixtures/api-source.json")))
  @operations Jason.decode!(File.read!(Path.join(__DIR__, "../specs/operations.json")))

  for {name, data} <- @fixtures["models"] do
    test "API serializer: #{name}" do
      module = Module.concat(Lettermint.Models, unquote(name))
      value = Model.from_map(module, unquote(Macro.escape(data)))
      assert value.__struct__ == module
      assert value.extra == %{}
      assert_complete(value)
    end
  end

  for {name, data} <- @fixtures["pages"] do
    test "API cursor page: #{name}" do
      value =
        Model.from_map(
          Module.concat(Lettermint.Models, unquote(name)),
          unquote(Macro.escape(data))
        )

      assert value.extra == %{}
      assert is_struct(hd(value.data))
      assert value.next_cursor != :unset
      assert value.per_page == 1
      assert_complete(value)
    end
  end

  for {name, values} <- @fixtures["enums"] do
    test "API enum: #{name}" do
      module = Module.concat(Lettermint.Models, unquote(name))
      values = unquote(values)
      # These internal cases are not in the public API enum.
      excluded =
        case unquote(name) do
          "SuppressionScope" -> ["global", "subscription_group"]
          "SuppressionReason" -> ["disposable_email"]
          _ -> []
        end

      assert Enum.sort(module.values()) == Enum.sort(values -- excluded)
    end
  end

  test "all public API routes are covered" do
    routes = MapSet.new(@fixtures["routes"], &{&1["method"], &1["path"]})
    generated = MapSet.new(@operations, &{&1["verb"], &1["path"]})
    assert routes == generated
    assert MapSet.size(routes) == 52
    assert length(@operations) == 53
  end

  for operation <- @operations do
    test "HTTP contract: #{operation["surface"]} #{operation["operationId"]}" do
      op = unquote(Macro.escape(operation))

      client =
        apply(Lettermint, if(op["surface"] == "sending", do: :email, else: :api), [
          "test-token",
          [adapter: Lettermint.TestAdapter]
        ])

      ids = Enum.map(op["params"], fn _ -> "id /?" end)
      args = [client] ++ ids ++ if(op["payload"], do: [%{"subject" => "test"}], else: [])

      Process.put(
        :response,
        {:ok, 200, if(op["response"] in [":ping", ":raw"], do: "pong", else: "null")}
      )

      assert {:ok, _} =
               apply(
                 Module.concat(String.split(op["module"], ".")),
                 String.to_atom(op["method"]),
                 args ++ [[query: %{"page[size]" => 2}, idempotency_key: "test-id"]]
               )

      assert_received {:request, request}
      expected = Regex.replace(~r/\{[^}]+\}/, op["path"], "id%20%2F%3F")
      assert request.url == "https://api.lettermint.co/v1" <> expected <> "?page%5Bsize%5D=2"
      assert request.method == String.to_existing_atom(String.downcase(op["verb"]))
      assert request.headers["idempotency-key"] == "test-id"

      if op["surface"] == "sending" do
        assert request.headers["x-lettermint-token"] == "test-token"
        refute Map.has_key?(request.headers, "authorization")
      else
        assert request.headers["authorization"] == "Bearer test-token"
        refute Map.has_key?(request.headers, "x-lettermint-token")
      end

      assert request.body == if(op["payload"], do: ~s({"subject":"test"}), else: nil)
    end
  end

  test "route settings use strings and statistics use a list" do
    value = Model.from_map(Lettermint.Models.RouteData, @fixtures["route_settings"])
    assert value.settings.attachment_delivery == "url"
    assert value.settings.tls == "enforced"
    assert value.statistics == []
  end

  for controller <- ["SendMailController", "SendBatchMailController"],
      mode <- ["immediate", "scheduled"] do
    test "#{controller} #{mode} response" do
      batch = unquote(controller) == "SendBatchMailController"
      data = @fixtures[unquote(controller)][unquote(mode)]
      Process.put(:response, {:ok, 202, Jason.encode!(if(batch, do: [data], else: data))})
      client = Lettermint.email("token", adapter: Lettermint.TestAdapter)

      {:ok, result} =
        if batch,
          do: Lettermint.Email.send_batch(client, [%{}]),
          else: Lettermint.Email.send(client, %{})

      value = if batch, do: hd(result), else: result
      assert Model.to_map(value) == data
    end
  end

  test "suppression deletion handles 200 and 202" do
    for {status, key} <- [{200, "suppression_removed"}, {202, "suppression_review"}] do
      Process.put(:response, {:ok, status, Jason.encode!(@fixtures[key])})

      assert {:ok, result} =
               Lettermint.Suppressions.delete(
                 Lettermint.api("token", adapter: Lettermint.TestAdapter),
                 "id"
               )

      assert result.extra == %{}
      assert Model.to_map(result) == @fixtures[key]
    end
  end

  test "PHP webhook signature fixture" do
    data = @fixtures["webhook_signature"]

    assert :ok =
             Lettermint.Webhook.verify(data["body"], data["signature"], "fixture-signing-secret",
               now: 1_788_782_400
             )
  end

  defp assert_complete(%{__struct__: _, extra: extra} = value) do
    assert extra == %{}

    value
    |> Map.from_struct()
    |> Map.delete(:extra)
    |> Map.values()
    |> Enum.each(&assert_complete/1)
  end

  defp assert_complete(value) when is_list(value), do: Enum.each(value, &assert_complete/1)
  defp assert_complete(_), do: :ok
end

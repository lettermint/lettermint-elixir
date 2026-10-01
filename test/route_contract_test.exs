defmodule Lettermint.RouteContractTest do
  use ExUnit.Case, async: true
  alias Lettermint.Model
  alias Lettermint.Models.RouteData

  test "the inbound route domain is optional and nullable" do
    for domain <- ["incoming.example.com", nil] do
      route = Model.from_map(RouteData, %{"inbound_route_domain" => domain})
      assert route.inbound_route_domain == domain
      assert route.extra == %{}
    end

    assert Model.from_map(RouteData, %{}).inbound_route_domain == :unset
  end
end

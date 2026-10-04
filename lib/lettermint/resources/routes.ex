defmodule Lettermint.Routes do
  @moduledoc """
  Routes of a project. Needs `:team_token`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists the routes of a project, one page at a time. `query`: `t:Lettermint.Types.ListRoutesQuery.t/0`."
  @spec list(Client.t(), String.t(), Types.ListRoutesQuery.t(), keyword()) ::
          result(Types.ListRoutesResponse.t())
  def list(%Client{} = client, project_id, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /projects/{projectId}/routes", %{
      label: "routes.list",
      path: %{"projectId" => project_id},
      query: query,
      options: options
    })
  end

  @doc "Streams every route of a project, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), String.t(), Types.ListRoutesQuery.t(), keyword()) ::
          Enumerable.t(Types.RouteListData.t())
  def iterate(%Client{} = client, project_id, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /projects/{projectId}/routes", %{
      label: "routes.iterate",
      path: %{"projectId" => project_id},
      query: query,
      options: options
    })
  end

  @doc "Creates a route in a project."
  @spec create(Client.t(), String.t(), Types.StoreRouteData.t() | map(), keyword()) ::
          result(Types.RouteMutationResponse.t())
  def create(%Client{} = client, project_id, body, options \\ []) do
    Transport.call(client, "POST /projects/{projectId}/routes", %{
      label: "routes.create",
      path: %{"projectId" => project_id},
      body: body,
      options: options
    })
  end

  @doc "Retrieves a route."
  @spec retrieve(Client.t(), String.t(), Types.GetRouteQuery.t(), keyword()) ::
          result(Types.RouteData.t())
  def retrieve(%Client{} = client, route_id, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /routes/{routeId}", %{
      label: "routes.retrieve",
      path: %{"routeId" => route_id},
      query: query,
      options: options
    })
  end

  @doc "Updates a route."
  @spec update(Client.t(), String.t(), Types.UpdateRouteData.t() | map(), keyword()) ::
          result(Types.RouteMutationResponse.t())
  def update(%Client{} = client, route_id, body, options \\ []) do
    Transport.call(client, "PUT /routes/{routeId}", %{
      label: "routes.update",
      path: %{"routeId" => route_id},
      body: body,
      options: options
    })
  end

  @doc "Deletes a route."
  @spec delete(Client.t(), String.t(), keyword()) :: result(Types.MessageResponse.t())
  def delete(%Client{} = client, route_id, options \\ []) do
    Transport.call(client, "DELETE /routes/{routeId}", %{
      label: "routes.delete",
      path: %{"routeId" => route_id},
      options: options
    })
  end

  @doc "Checks the inbound domain of a route."
  @spec verify_inbound_domain(Client.t(), String.t(), keyword()) ::
          result(Types.InboundDomainVerificationResponse.t())
  def verify_inbound_domain(%Client{} = client, route_id, options \\ []) do
    Transport.call(client, "POST /routes/{routeId}/verify-inbound-domain", %{
      label: "routes.verify_inbound_domain",
      path: %{"routeId" => route_id},
      options: options
    })
  end
end

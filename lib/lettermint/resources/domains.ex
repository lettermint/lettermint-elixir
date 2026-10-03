defmodule Lettermint.Domains do
  @moduledoc """
  Sending domains. Needs `:team_token`.

  Every function takes the options `timeout:` (milliseconds) last. Query
  arguments are maps with nested maps for bracketed names; see
  `Lettermint.Query`.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists domains, one page at a time. `query`: `t:Lettermint.Types.ListDomainsQuery.t/0`."
  @spec list(Client.t(), Types.ListDomainsQuery.t(), keyword()) ::
          result(Types.ListDomainsResponse.t())
  def list(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /domains", %{
      label: "domains.list",
      query: query,
      options: options
    })
  end

  @doc "Streams every domain, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), Types.ListDomainsQuery.t(), keyword()) ::
          Enumerable.t(Types.DomainListData.t())
  def iterate(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /domains", %{
      label: "domains.iterate",
      query: query,
      options: options
    })
  end

  @doc "Adds a domain."
  @spec create(Client.t(), Types.StoreDomainData.t() | map(), keyword()) ::
          result(Types.DomainData.t())
  def create(%Client{} = client, body, options \\ []) do
    Transport.call(client, "POST /domains", %{
      label: "domains.create",
      body: body,
      options: options
    })
  end

  @doc "Retrieves a domain. `query`: `%{include: [\"dnsRecords\"]}` and so on."
  @spec retrieve(Client.t(), String.t(), Types.GetDomainQuery.t(), keyword()) ::
          result(Types.DomainData.t())
  def retrieve(%Client{} = client, domain_id, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /domains/{domainId}", %{
      label: "domains.retrieve",
      path: %{"domainId" => domain_id},
      query: query,
      options: options
    })
  end

  @doc "Deletes a domain."
  @spec delete(Client.t(), String.t(), keyword()) :: result(Types.MessageResponse.t())
  def delete(%Client{} = client, domain_id, options \\ []) do
    Transport.call(client, "DELETE /domains/{domainId}", %{
      label: "domains.delete",
      path: %{"domainId" => domain_id},
      options: options
    })
  end

  @doc "Checks every DNS record of the domain."
  @spec verify_dns_records(Client.t(), String.t(), keyword()) ::
          result(Types.DnsVerificationSuccessResponse.t())
  def verify_dns_records(%Client{} = client, domain_id, options \\ []) do
    Transport.call(client, "POST /domains/{domainId}/dns-records/verify", %{
      label: "domains.verify_dns_records",
      path: %{"domainId" => domain_id},
      options: options
    })
  end

  @doc "Checks one DNS record of the domain."
  @spec verify_dns_record(Client.t(), String.t(), String.t(), keyword()) ::
          result(Types.MessageResponse.t())
  def verify_dns_record(%Client{} = client, domain_id, record_id, options \\ []) do
    Transport.call(client, "POST /domains/{domainId}/dns-records/{recordId}/verify", %{
      label: "domains.verify_dns_record",
      path: %{"domainId" => domain_id, "recordId" => record_id},
      options: options
    })
  end

  @doc "Replaces the projects that may send from the domain."
  @spec update_projects(
          Client.t(),
          String.t(),
          Types.UpdateDomainProjectsData.t() | map(),
          keyword()
        ) ::
          result(Types.DomainMutationResponse.t())
  def update_projects(%Client{} = client, domain_id, body, options \\ []) do
    Transport.call(client, "PUT /domains/{domainId}/projects", %{
      label: "domains.update_projects",
      path: %{"domainId" => domain_id},
      body: body,
      options: options
    })
  end
end

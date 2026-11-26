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

  @doc """
  Starts the managed DKIM upgrade of a `legacy_txt` domain. `data.dns_records`
  lists two new DKIM CNAME records with `verification_scope` `"migration"`;
  add them to your DNS. The current DKIM TXT record keeps signing until the
  upgrade completes. When `data.dkim_transition.state` is
  `"ready_to_activate"`, call `activate_dkim_upgrade/3`.

  Calling it again returns the upgrade that is in progress. For a domain that
  already uses managed DKIM nothing changes. A domain that cannot be upgraded
  returns a `Lettermint.ValidationError` (422).
  """
  @spec start_dkim_upgrade(Client.t(), String.t(), keyword()) ::
          result(Types.DomainMutationResponse.t())
  def start_dkim_upgrade(%Client{} = client, domain_id, options \\ []) do
    Transport.call(client, "POST /domains/{domainId}/dkim/upgrade", %{
      label: "domains.start_dkim_upgrade",
      path: %{"domainId" => domain_id},
      options: options
    })
  end

  @doc """
  Cancels the managed DKIM upgrade and removes its DKIM CNAME records. The
  domain keeps its DKIM TXT record. Without an upgrade in progress nothing
  changes, and a key rotation is never cancelled. After the grace period
  started, the upgrade cannot be cancelled: the API returns a
  `Lettermint.ValidationError` (422).
  """
  @spec cancel_dkim_upgrade(Client.t(), String.t(), keyword()) ::
          result(Types.DomainMutationResponse.t())
  def cancel_dkim_upgrade(%Client{} = client, domain_id, options \\ []) do
    Transport.call(client, "DELETE /domains/{domainId}/dkim/upgrade", %{
      label: "domains.cancel_dkim_upgrade",
      path: %{"domainId" => domain_id},
      options: options
    })
  end

  @doc """
  Activates the managed DKIM upgrade. Lettermint checks both DKIM CNAME
  records again, then starts a grace period in which both keys are published.
  The upgrade completes at `data.dkim_transition.completes_after`, and
  `dkim_mode` then changes to `"managed_cname"`; after that you can remove the
  old DKIM TXT record.

  Calling it again during the grace period, or after the upgrade completed,
  changes nothing. Without an upgrade, or before it is ready, the API returns
  a `Lettermint.ValidationError` (422).
  """
  @spec activate_dkim_upgrade(Client.t(), String.t(), keyword()) ::
          result(Types.DomainMutationResponse.t())
  def activate_dkim_upgrade(%Client{} = client, domain_id, options \\ []) do
    Transport.call(client, "POST /domains/{domainId}/dkim/upgrade/activate", %{
      label: "domains.activate_dkim_upgrade",
      path: %{"domainId" => domain_id},
      options: options
    })
  end

  @doc """
  Starts a DKIM key rotation for a domain with managed DKIM. The DKIM CNAME
  records stay the same, so no DNS change is needed. Lettermint publishes the
  new key, then keeps both keys published during a grace period. Lettermint
  also rotates keys on a schedule, so you only need this to replace a key
  early.

  Calling it again during a rotation returns the rotation that is in
  progress. A domain that cannot be rotated returns a
  `Lettermint.ValidationError` (422).
  """
  @spec rotate_dkim_key(Client.t(), String.t(), keyword()) ::
          result(Types.DomainMutationResponse.t())
  def rotate_dkim_key(%Client{} = client, domain_id, options \\ []) do
    Transport.call(client, "POST /domains/{domainId}/dkim/rotate", %{
      label: "domains.rotate_dkim_key",
      path: %{"domainId" => domain_id},
      options: options
    })
  end
end

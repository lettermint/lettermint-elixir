defmodule Lettermint.Projects do
  @moduledoc """
  Projects. Needs `:team_token`. Report forwarding is in
  `Lettermint.Projects.ReportForwarding`, routes in `Lettermint.Routes`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists projects, one page at a time. `query`: `t:Lettermint.Types.ListProjectsQuery.t/0`."
  @spec list(Client.t(), Types.ListProjectsQuery.t(), keyword()) ::
          result(Types.ListProjectsResponse.t())
  def list(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /projects", %{
      label: "projects.list",
      query: query,
      options: options
    })
  end

  @doc "Streams every project, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), Types.ListProjectsQuery.t(), keyword()) ::
          Enumerable.t(Types.ProjectListData.t())
  def iterate(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /projects", %{
      label: "projects.iterate",
      query: query,
      options: options
    })
  end

  @doc "Creates a project. The response holds its sending token once (`api_token`)."
  @spec create(Client.t(), Types.StoreProjectData.t() | map(), keyword()) ::
          result(Types.ProjectCreatedData.t())
  def create(%Client{} = client, body, options \\ []) do
    Transport.call(client, "POST /projects", %{
      label: "projects.create",
      body: body,
      options: options
    })
  end

  @doc "Retrieves a project."
  @spec retrieve(Client.t(), String.t(), Types.GetProjectQuery.t(), keyword()) ::
          result(Types.ProjectData.t())
  def retrieve(%Client{} = client, project_id, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /projects/{projectId}", %{
      label: "projects.retrieve",
      path: %{"projectId" => project_id},
      query: query,
      options: options
    })
  end

  @doc "Updates a project."
  @spec update(Client.t(), String.t(), Types.UpdateProjectData.t() | map(), keyword()) ::
          result(Types.ProjectMutationResponse.t())
  def update(%Client{} = client, project_id, body, options \\ []) do
    Transport.call(client, "PUT /projects/{projectId}", %{
      label: "projects.update",
      path: %{"projectId" => project_id},
      body: body,
      options: options
    })
  end

  @doc "Deletes a project."
  @spec delete(Client.t(), String.t(), keyword()) :: result(Types.MessageResponse.t())
  def delete(%Client{} = client, project_id, options \\ []) do
    Transport.call(client, "DELETE /projects/{projectId}", %{
      label: "projects.delete",
      path: %{"projectId" => project_id},
      options: options
    })
  end

  @doc "Rotates the project's legacy sending token. The API marks this endpoint as legacy."
  @doc deprecated: "The API marks this endpoint as legacy."
  @spec rotate_token(Client.t(), String.t(), keyword()) ::
          result(Types.RotateProjectTokenResponse.t())
  def rotate_token(%Client{} = client, project_id, options \\ []) do
    Transport.call(client, "POST /projects/{projectId}/rotate-token", %{
      label: "projects.rotate_token",
      path: %{"projectId" => project_id},
      options: options
    })
  end
end

defmodule Lettermint.Projects.ReportForwarding do
  @moduledoc """
  DMARC and complaint report forwarding of a project. Needs `:team_token`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "The report forwarding settings of a project."
  @spec retrieve(Client.t(), String.t(), keyword()) ::
          result(Types.GetReportForwardingResponse.t())
  def retrieve(%Client{} = client, project_id, options \\ []) do
    Transport.call(client, "GET /projects/{projectId}/report-forwarding", %{
      label: "projects.report_forwarding.retrieve",
      path: %{"projectId" => project_id},
      options: options
    })
  end

  @doc "Sets the report forwarding address."
  @spec update(Client.t(), String.t(), Types.ReportForwardingRequest.t() | map(), keyword()) ::
          result(Types.UpdateReportForwardingResponse.t())
  def update(%Client{} = client, project_id, body, options \\ []) do
    Transport.call(client, "PUT /projects/{projectId}/report-forwarding", %{
      label: "projects.report_forwarding.update",
      path: %{"projectId" => project_id},
      body: body,
      options: options
    })
  end

  @doc "Disables report forwarding. Returns `:ok` (HTTP 204)."
  @spec delete(Client.t(), String.t(), keyword()) :: :ok | {:error, Lettermint.Error.t()}
  def delete(%Client{} = client, project_id, options \\ []) do
    Transport.call(client, "DELETE /projects/{projectId}/report-forwarding", %{
      label: "projects.report_forwarding.delete",
      path: %{"projectId" => project_id},
      options: options
    })
  end

  @doc "Verifies the forwarding address with the emailed code."
  @spec verify(Client.t(), String.t(), Types.VerifyReportForwardingRequest.t() | map(), keyword()) ::
          result(Types.VerifyReportForwardingResponse.t())
  def verify(%Client{} = client, project_id, body, options \\ []) do
    Transport.call(client, "POST /projects/{projectId}/report-forwarding/verify", %{
      label: "projects.report_forwarding.verify",
      path: %{"projectId" => project_id},
      body: body,
      options: options
    })
  end

  @doc "Sends the verification code again."
  @spec resend_code(Client.t(), String.t(), keyword()) ::
          result(Types.ResendReportForwardingCodeResponse.t())
  def resend_code(%Client{} = client, project_id, options \\ []) do
    Transport.call(client, "POST /projects/{projectId}/report-forwarding/resend-code", %{
      label: "projects.report_forwarding.resend_code",
      path: %{"projectId" => project_id},
      options: options
    })
  end
end

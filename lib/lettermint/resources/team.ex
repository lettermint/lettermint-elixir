defmodule Lettermint.Stats do
  @moduledoc "Sending statistics. Needs `:team_token`."

  alias Lettermint.{Client, Transport, Types}

  @doc """
  Daily statistics between `from` and `to` (`Y-m-d`, at most 90 days).
  `query`: `%{from: "2026-10-01", to: "2026-10-31", project_id: ..., include_machine: true}`.
  """
  @spec retrieve(Client.t(), Types.GetStatsQuery.t(), keyword()) ::
          {:ok, Types.StatsData.t()} | {:error, Lettermint.Error.t()}
  def retrieve(%Client{} = client, query, options \\ []) do
    Transport.call(client, "GET /stats", %{
      label: "stats.retrieve",
      query: query,
      options: options
    })
  end
end

defmodule Lettermint.Suppressions do
  @moduledoc """
  The suppression list. Needs `:team_token`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists suppressions, one page at a time. `query`: `t:Lettermint.Types.ListSuppressionsQuery.t/0`."
  @spec list(Client.t(), Types.ListSuppressionsQuery.t(), keyword()) ::
          result(Types.ListSuppressionsResponse.t())
  def list(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /suppressions", %{
      label: "suppressions.list",
      query: query,
      options: options
    })
  end

  @doc "Streams every suppression, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), Types.ListSuppressionsQuery.t(), keyword()) ::
          Enumerable.t(Types.SuppressedRecipientData.t())
  def iterate(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /suppressions", %{
      label: "suppressions.iterate",
      query: query,
      options: options
    })
  end

  @doc "Adds a suppression."
  @spec create(Client.t(), Types.StoreSuppressionData.t() | map(), keyword()) ::
          result(Types.SuppressionStoreResponse.t())
  def create(%Client{} = client, body, options \\ []) do
    Transport.call(client, "POST /suppressions", %{
      label: "suppressions.create",
      body: body,
      options: options
    })
  end

  @doc """
  Removes a suppression. Some removals are reviewed first: then `status` is
  not `"removed"` and `ticket_identifier` names the review.
  """
  @spec delete(Client.t(), String.t(), keyword()) :: result(Types.DeleteSuppressionResponse.t())
  def delete(%Client{} = client, suppression_id, options \\ []) do
    Transport.call(client, "DELETE /suppressions/{suppressionId}", %{
      label: "suppressions.delete",
      path: %{"suppressionId" => suppression_id},
      options: options
    })
  end
end

defmodule Lettermint.Team do
  @moduledoc """
  The team of the token. Needs `:team_token`. Members are in
  `Lettermint.Team.Members`, pending invitations in `Lettermint.Team.Invites`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "The team. `query`: `%{include: [\"features\"]}` and so on."
  @spec retrieve(Client.t(), Types.GetTeamQuery.t(), keyword()) :: result(Types.TeamData.t())
  def retrieve(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /team", %{label: "team.retrieve", query: query, options: options})
  end

  @doc "Updates the team."
  @spec update(Client.t(), Types.UpdateTeamData.t() | map(), keyword()) ::
          result(Types.TeamMutationResponse.t())
  def update(%Client{} = client, body, options \\ []) do
    Transport.call(client, "PUT /team", %{label: "team.update", body: body, options: options})
  end

  @doc "Usage of the current and previous billing periods."
  @spec usage(Client.t(), keyword()) :: result(Types.TeamUsageDetailData.t())
  def usage(%Client{} = client, options \\ []) do
    Transport.call(client, "GET /team/usage", %{label: "team.usage", options: options})
  end

  @doc "The roles that can be assigned to members."
  @spec roles(Client.t(), keyword()) :: result(Types.TeamRoleListResponse.t())
  def roles(%Client{} = client, options \\ []) do
    Transport.call(client, "GET /team/roles", %{label: "team.roles", options: options})
  end

  @doc "Retrieves a role."
  @spec retrieve_role(Client.t(), String.t(), keyword()) :: result(Types.TeamRoleData.t())
  def retrieve_role(%Client{} = client, role_id, options \\ []) do
    Transport.call(client, "GET /team/roles/{roleId}", %{
      label: "team.retrieve_role",
      path: %{"roleId" => role_id},
      options: options
    })
  end

  @doc """
  Creates a custom role. Needs a plan with custom roles. `permissions` must
  include the permissions they depend on, and role names are unique.
  """
  @spec create_role(Client.t(), Types.CreateTeamRoleData.t() | map(), keyword()) ::
          result(Types.TeamRoleData.t())
  def create_role(%Client{} = client, body, options \\ []) do
    Transport.call(client, "POST /team/roles", %{
      label: "team.create_role",
      body: body,
      options: options
    })
  end

  @doc "Replaces the name, description and permissions of a custom role. Built-in roles cannot be changed."
  @spec update_role(Client.t(), String.t(), Types.UpdateTeamRoleData.t() | map(), keyword()) ::
          result(Types.TeamRoleData.t())
  def update_role(%Client{} = client, role_id, body, options \\ []) do
    Transport.call(client, "PUT /team/roles/{roleId}", %{
      label: "team.update_role",
      path: %{"roleId" => role_id},
      body: body,
      options: options
    })
  end

  @doc """
  Deletes a custom role. Built-in roles cannot be deleted. `query`:
  `%{replacement_role_id: ...}`, the role that receives the existing
  assignments; it is required only while the role is still assigned to
  members, invites or SCIM groups.
  """
  @spec delete_role(Client.t(), String.t(), Types.DeleteTeamRoleQuery.t(), keyword()) ::
          result(Types.MessageResponse.t())
  def delete_role(%Client{} = client, role_id, query \\ %{}, options \\ []) do
    Transport.call(client, "DELETE /team/roles/{roleId}", %{
      label: "team.delete_role",
      path: %{"roleId" => role_id},
      query: query,
      options: options
    })
  end

  @doc """
  Copies a role under a new name. Without a `description`, the copy keeps the
  description of the source role. The Owner role cannot be duplicated.
  """
  @spec duplicate_role(Client.t(), String.t(), Types.DuplicateTeamRoleData.t() | map(), keyword()) ::
          result(Types.TeamRoleData.t())
  def duplicate_role(%Client{} = client, role_id, body, options \\ []) do
    Transport.call(client, "POST /team/roles/{roleId}/duplicate", %{
      label: "team.duplicate_role",
      path: %{"roleId" => role_id},
      body: body,
      options: options
    })
  end
end

defmodule Lettermint.Team.Members do
  @moduledoc """
  Team members. Needs `:team_token`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists team members, one page at a time. `query`: `t:Lettermint.Types.ListTeamMembersQuery.t/0`."
  @spec list(Client.t(), Types.ListTeamMembersQuery.t(), keyword()) ::
          result(Types.ListTeamMembersResponse.t())
  def list(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /team/members", %{
      label: "team.members.list",
      query: query,
      options: options
    })
  end

  @doc "Streams every team member, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), Types.ListTeamMembersQuery.t(), keyword()) ::
          Enumerable.t(Types.TeamMemberData.t())
  def iterate(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /team/members", %{
      label: "team.members.iterate",
      query: query,
      options: options
    })
  end

  @doc "Retrieves a team member."
  @spec retrieve(Client.t(), String.t(), keyword()) :: result(Types.TeamMemberData.t())
  def retrieve(%Client{} = client, user_id, options \\ []) do
    Transport.call(client, "GET /team/members/{userId}", %{
      label: "team.members.retrieve",
      path: %{"userId" => user_id},
      options: options
    })
  end

  @doc "Changes a member's role and project access."
  @spec update_assignment(
          Client.t(),
          String.t(),
          Types.UpdateTeamMemberAssignmentData.t() | map(),
          keyword()
        ) ::
          result(Types.TeamMemberData.t())
  def update_assignment(%Client{} = client, user_id, body, options \\ []) do
    Transport.call(client, "PUT /team/members/{userId}/assignment", %{
      label: "team.members.update_assignment",
      path: %{"userId" => user_id},
      body: body,
      options: options
    })
  end
end

defmodule Lettermint.Team.Invites do
  @moduledoc """
  Pending team invitations. Needs `:team_token`.

  Every function takes the options `timeout:` (milliseconds) last.
  """

  alias Lettermint.{Client, Transport, Types}

  @type result(value) :: {:ok, value} | {:error, Lettermint.Error.t()}

  @doc "Lists pending invitations, one page at a time. `query`: `t:Lettermint.Types.ListTeamInvitesQuery.t/0`."
  @spec list(Client.t(), Types.ListTeamInvitesQuery.t(), keyword()) ::
          result(Types.ListTeamInvitesResponse.t())
  def list(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.call(client, "GET /team/invites", %{
      label: "team.invites.list",
      query: query,
      options: options
    })
  end

  @doc "Streams every pending invitation, following `next_cursor`. Raises the error of a failed page request."
  @spec iterate(Client.t(), Types.ListTeamInvitesQuery.t(), keyword()) ::
          Enumerable.t(Types.TeamInviteData.t())
  def iterate(%Client{} = client, query \\ %{}, options \\ []) do
    Transport.paginate(client, "GET /team/invites", %{
      label: "team.invites.iterate",
      query: query,
      options: options
    })
  end

  @doc "Retrieves a pending invitation."
  @spec retrieve(Client.t(), String.t(), keyword()) :: result(Types.TeamInviteData.t())
  def retrieve(%Client{} = client, invite_id, options \\ []) do
    Transport.call(client, "GET /team/invites/{inviteId}", %{
      label: "team.invites.retrieve",
      path: %{"inviteId" => invite_id},
      options: options
    })
  end

  @doc """
  Invites a person to the team and sends the invitation email. The team needs
  a free seat, and the Owner role cannot be assigned.
  """
  @spec create(Client.t(), Types.CreateTeamInviteData.t() | map(), keyword()) ::
          result(Types.TeamInviteData.t())
  def create(%Client{} = client, body, options \\ []) do
    Transport.call(client, "POST /team/invites", %{
      label: "team.invites.create",
      body: body,
      options: options
    })
  end

  @doc """
  Replaces the email, role and project access of a pending invitation. A new
  invitation email is sent only when the address changes.
  """
  @spec update(Client.t(), String.t(), Types.UpdateTeamInviteData.t() | map(), keyword()) ::
          result(Types.TeamInviteData.t())
  def update(%Client{} = client, invite_id, body, options \\ []) do
    Transport.call(client, "PUT /team/invites/{inviteId}", %{
      label: "team.invites.update",
      path: %{"inviteId" => invite_id},
      body: body,
      options: options
    })
  end

  @doc "Revokes a pending invitation."
  @spec revoke(Client.t(), String.t(), keyword()) :: result(Types.MessageResponse.t())
  def revoke(%Client{} = client, invite_id, options \\ []) do
    Transport.call(client, "DELETE /team/invites/{inviteId}", %{
      label: "team.invites.revoke",
      path: %{"inviteId" => invite_id},
      options: options
    })
  end
end

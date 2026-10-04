ExUnit.start()

defmodule Lettermint.TestAdapter do
  @moduledoc false
  # Records each request in the test process and answers with `respond`.
  @behaviour Lettermint.Adapter

  @impl true
  def request(request, options) do
    send(Keyword.fetch!(options, :test), {:request, request})
    Keyword.fetch!(options, :respond).(request)
  end
end

defmodule Lettermint.TestHelpers do
  @moduledoc false

  @sending "lm_TestSendingToken0123456789abcdef"
  @team "lm_team_TestTeamToken0123456789abcdefABCDEFGH"

  def sending_token, do: @sending
  def team_token, do: @team

  def json(status, body, headers \\ []),
    do:
      {:ok,
       %{
         status: status,
         headers: [{"content-type", "application/json"} | headers],
         body: Jason.encode!(body)
       }}

  def raw(status, body, headers \\ []), do: {:ok, %{status: status, headers: headers, body: body}}

  @doc "A client whose adapter answers with `respond` (a response or a function of the request)."
  def client(options \\ [], respond \\ json(200, %{})) do
    respond = if is_function(respond, 1), do: respond, else: fn _ -> respond end

    options =
      Keyword.merge(
        [sending_token: @sending, team_token: @team],
        Keyword.put(options, :adapter, {Lettermint.TestAdapter, test: self(), respond: respond})
      )

    Lettermint.new(for {key, value} <- options, value != :none, do: {key, value})
  end

  def sending_client(respond \\ json(202, %{message_id: "msg", status: "pending"})),
    do: client([team_token: :none], respond)

  def team_client(respond \\ json(200, %{})), do: client([sending_token: :none], respond)

  def header(request, name) do
    Enum.find_value(request.headers, fn {key, value} -> if key == name, do: value end)
  end

  def path(request), do: request.url |> URI.parse() |> Map.fetch!(:path)
  def query(request), do: request.url |> URI.parse() |> Map.fetch!(:query)
end

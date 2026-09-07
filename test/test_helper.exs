ExUnit.start()

defmodule Lettermint.TestAdapter do
  @behaviour Lettermint.Adapter
  def request(request) do
    send(self(), {:request, request})
    Process.get(:response, {:ok, 204, ""})
  end
end

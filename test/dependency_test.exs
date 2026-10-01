defmodule Lettermint.DependencyTest do
  use ExUnit.Case, async: true

  test "package dependency requirements exclude vulnerable Mint versions" do
    {:mint, requirement} = List.keyfind(Mix.Project.config()[:deps], :mint, 0)

    for version <- ["1.9.3", "1.10.0", "1.10.1"] do
      refute Version.match?(version, requirement)
    end

    assert Version.match?("1.10.2", requirement)
  end
end

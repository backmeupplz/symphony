defmodule SymphonyElixir.ProjectIconTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.ProjectIcon

  test "resolves explicit Kaneo and config icon names before curated defaults" do
    icon =
      ProjectIcon.resolve(%{
        project_icon: "Mic",
        project_slug: "sym",
        project_name: "Symphony"
      })

    assert icon.type == "svg"
    assert icon.icon == "audio"
    assert icon.label == "Voice project"
    assert ProjectIcon.paths(icon.icon) != []
  end

  test "uses curated defaults for known portfolio projects" do
    assert ProjectIcon.resolve(%{project_slug: "voi"}).icon == "audio"
    assert ProjectIcon.resolve(%{project_name: "MyGround"}).icon == "map"
    assert ProjectIcon.resolve(%{project_key: "EGG"}).icon == "egg"
    assert ProjectIcon.resolve(%{project_slug: "mkt"}).icon == "megaphone"
    assert ProjectIcon.resolve(%{project_name: "Symphony"}).icon == "bot"
  end

  test "falls back to deterministic initials and accent colors" do
    first = ProjectIcon.resolve(%{project_name: "Atlas Ops"})
    second = ProjectIcon.resolve(%{project_name: "Atlas Ops"})
    other = ProjectIcon.resolve(%{project_name: "Billing"})

    assert first.type == "initials"
    assert first.initials == "AO"
    assert first.background == second.background
    assert first.color == second.color
    assert {first.background, first.color} != {other.background, other.color}
  end
end

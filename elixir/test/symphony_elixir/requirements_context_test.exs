defmodule SymphonyElixir.RequirementsContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RequirementsContext

  test "revision is deterministic and limited to canonical requirement fields" do
    issue = %Issue{
      id: "issue-1",
      identifier: "OCL-1",
      title: "Steer the worker",
      description: "Deliver changed requirements",
      requirement_updates: ["## Requirements Update\nAdd Expand all and Collapse all."],
      state: "in-progress",
      updated_at: ~U[2026-07-24 17:00:00Z]
    }

    revision = RequirementsContext.revision(issue)

    assert revision == RequirementsContext.revision(%{issue | state: "in-review"})
    assert revision == RequirementsContext.revision(%{issue | updated_at: ~U[2026-07-24 18:00:00Z]})

    assert revision ==
             issue
             |> Map.from_struct()
             |> Map.put(:activity, [%{content: "## Codex Workpad\nprogress update"}])
             |> RequirementsContext.revision()

    refute revision ==
             RequirementsContext.revision(%{
               issue
               | requirement_updates: [
                   "## Requirements Update\nAdd Expand all and Collapse all.",
                   "## Requirements Update\nKeep the controls visible on mobile."
                 ]
             })

    refute revision ==
             RequirementsContext.revision(%{issue | description: "Deliver changed requirements now"})
  end

  test "only explicitly tagged Kaneo comments become operator requirement updates" do
    activities = [
      %{
        "id" => "requirement-2",
        "type" => "comment",
        "content" => "## Requirements Update\r\nKeep the controls visible on mobile.",
        "createdAt" => "2026-07-24T18:02:00Z"
      },
      %{
        "id" => "workpad",
        "type" => "comment",
        "content" => "## Codex Workpad\n- [x] progress",
        "createdAt" => "2026-07-24T18:03:00Z"
      },
      %{
        "id" => "ordinary",
        "type" => "comment",
        "content" => "Could you take another look?",
        "createdAt" => "2026-07-24T18:04:00Z"
      },
      %{
        "id" => "requirement-1",
        "type" => "comment",
        "content" => "## Requirements Update\nAdd Expand all and Collapse all.",
        "createdAt" => "2026-07-24T18:01:00Z"
      },
      %{
        "id" => "status",
        "type" => "status_changed",
        "content" => "## Requirements Update\nThis is not comment activity.",
        "createdAt" => "2026-07-24T18:00:00Z"
      }
    ]

    assert RequirementsContext.operator_requirement_updates(activities) == [
             "## Requirements Update\nAdd Expand all and Collapse all.",
             "## Requirements Update\nKeep the controls visible on mobile."
           ]
  end

  test "steer prompt contains a mandatory concise delta and full canonical context" do
    previous = %{title: "Old title", description: "Original requirement", requirement_updates: []}

    issue = %Issue{
      identifier: "OCL-1",
      title: "New title",
      description: "Original requirement\n\n- Add the new behavior",
      requirement_updates: ["## Requirements Update\nAlso preserve the compact layout."]
    }

    prompt = RequirementsContext.steer_prompt(issue, previous)

    assert prompt =~ "Requirements changed while this turn is active"
    assert prompt =~ "reconcile these requirements before further edits, validation, or completion"
    assert prompt =~ "Title changed"
    assert prompt =~ "New title"
    assert prompt =~ "Add the new behavior"
    assert prompt =~ "Operator requirements changed"
    assert prompt =~ "Also preserve the compact layout"
  end

  test "completion gate forces current requirements into a continuation before handoff" do
    issue = %Issue{
      id: "issue-gate",
      identifier: "OCL-27",
      title: "Original title",
      description: "Original requirements",
      state: "in-progress"
    }

    delivered_revision = RequirementsContext.revision(issue)

    refreshed_issue = %{
      issue
      | description: "Original requirements\n\nAdd collapse all",
        state: "in-review"
    }

    assert {:reconcile, ^refreshed_issue, refreshed_revision} =
             AgentRunner.completion_decision_for_test(
               issue,
               fn ["issue-gate"] -> {:ok, [refreshed_issue]} end,
               delivered_revision
             )

    assert refreshed_revision == RequirementsContext.revision(refreshed_issue)

    assert {:done, ^refreshed_issue} =
             AgentRunner.completion_decision_for_test(
               refreshed_issue,
               fn ["issue-gate"] -> {:ok, [refreshed_issue]} end,
               refreshed_revision
             )
  end
end

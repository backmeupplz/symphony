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
             RequirementsContext.revision(%{issue | description: "Deliver changed requirements now"})
  end

  test "steer prompt contains a mandatory concise delta and full canonical context" do
    previous = %{title: "Old title", description: "Original requirement"}

    issue = %Issue{
      identifier: "OCL-1",
      title: "New title",
      description: "Original requirement\n\n- Add the new behavior"
    }

    prompt = RequirementsContext.steer_prompt(issue, previous)

    assert prompt =~ "Requirements changed while this turn is active"
    assert prompt =~ "reconcile these requirements before further edits, validation, or completion"
    assert prompt =~ "Title changed"
    assert prompt =~ "New title"
    assert prompt =~ "Add the new behavior"
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

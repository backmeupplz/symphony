defmodule SymphonyElixir.KaneoClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Kaneo.Client, as: KaneoClient

  test "normalizes Kaneo task payloads to issues" do
    issue =
      KaneoClient.normalize_task_for_test(%{
        "id" => "task-1",
        "number" => 42,
        "title" => "Build the thing",
        "description" => "Do it",
        "status" => "ready-for-build",
        "priority" => "urgent",
        "userId" => "user-1",
        "createdAt" => "2026-04-30T12:00:00Z"
      })

    assert issue.id == "task-1"
    assert issue.identifier == "KANEO-42"
    assert issue.title == "Build the thing"
    assert issue.description == "Do it"
    assert issue.state == "ready-for-build"
    assert issue.priority == 1
    assert issue.assignee_id == "user-1"
    assert issue.created_at == ~U[2026-04-30 12:00:00Z]
  end

  test "flattens Kaneo column task responses" do
    response = %{
      "data" => %{
        "columns" => [
          %{"status" => "ready-for-build", "tasks" => [%{"id" => "task-1"}]},
          %{"status" => "qa-needed", "tasks" => [%{"id" => "task-2"}]},
          %{"status" => "empty"}
        ]
      },
      "pagination" => %{"total" => 2}
    }

    assert [%{"id" => "task-1"}, %{"id" => "task-2"}] =
             KaneoClient.flatten_tasks_response_for_test(response)
  end
end

defmodule SymphonyElixir.KaneoClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Kaneo.Client, as: KaneoClient

  setup do
    previous_request_fun = Application.get_env(:symphony_elixir, :kaneo_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :kaneo_request_fun)
      else
        Application.put_env(:symphony_elixir, :kaneo_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

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

  test "normalizes Kaneo tasks with project-aware identifiers and repo routing" do
    issue =
      KaneoClient.normalize_task_for_test(
        %{
          "id" => "task-1",
          "number" => 7,
          "title" => "Build routed task",
          "description" => "SOURCE_REPO_REF=feature/task-branch",
          "status" => "to-do",
          "projectId" => "project-a"
        },
        %{
          id: "project-a",
          name: "Project Alpha",
          slug: "alpha",
          repo_url: "git@example.com:alpha/repo.git",
          repo_ref: "main",
          workflow_file: "/opt/alpha/WORKFLOW.md"
        }
      )

    assert issue.identifier == "ALPHA-KANEO-7"
    assert issue.tracker_identifier == "KANEO-7"
    assert issue.project_id == "project-a"
    assert issue.project_name == "Project Alpha"
    assert issue.project_slug == "alpha"
    assert issue.project_key == "ALPHA"
    assert issue.source_repo_url == "git@example.com:alpha/repo.git"
    assert issue.source_repo_ref == "feature/task-branch"
    assert issue.workflow_file == "/opt/alpha/WORKFLOW.md"
  end

  test "fetches candidate issues from multiple configured Kaneo projects" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "kaneo",
      tracker_endpoint: "https://kaneo.test/api",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_id: nil,
      tracker_active_states: ["to-do"],
      tracker_terminal_states: ["done"],
      tracker_projects: [
        %{
          id: "project-a",
          slug: "alpha",
          repo_url: "git@example.com:alpha/repo.git"
        },
        %{
          id: "project-b",
          slug: "beta",
          repo_url: "git@example.com:beta/repo.git"
        }
      ]
    )

    Application.put_env(:symphony_elixir, :kaneo_request_fun, fn opts ->
      send(self(), {:kaneo_request, opts[:url], opts[:params]})

      body =
        cond do
          String.ends_with?(opts[:url], "/task/tasks/project-a") ->
            %{
              "data" => %{
                "columns" => [
                  %{
                    "tasks" => [
                      %{
                        "id" => "task-a",
                        "number" => 1,
                        "title" => "Alpha task",
                        "status" => "to-do",
                        "projectId" => "project-a"
                      }
                    ]
                  }
                ]
              }
            }

          String.ends_with?(opts[:url], "/task/tasks/project-b") ->
            %{
              "data" => %{
                "columns" => [
                  %{
                    "tasks" => [
                      %{
                        "id" => "task-b",
                        "number" => 1,
                        "title" => "Beta task",
                        "status" => "to-do",
                        "projectId" => "project-b"
                      }
                    ]
                  }
                ]
              }
            }
        end

      {:ok, %Req.Response{status: 200, body: body}}
    end)

    assert {:ok, issues} = KaneoClient.fetch_candidate_issues()

    assert Enum.map(issues, & &1.identifier) == ["ALPHA-KANEO-1", "BETA-KANEO-1"]

    assert Enum.map(issues, & &1.source_repo_url) == [
             "git@example.com:alpha/repo.git",
             "git@example.com:beta/repo.git"
           ]

    assert_receive {:kaneo_request, "https://kaneo.test/api/task/tasks/project-a", [status: "to-do", sortBy: "priority", sortOrder: "asc"]}

    assert_receive {:kaneo_request, "https://kaneo.test/api/task/tasks/project-b", [status: "to-do", sortBy: "priority", sortOrder: "asc"]}
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

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
          "description" => "SOURCE_REPO_KEY=frontend\nSOURCE_REPO_REF=feature/task-branch",
          "status" => "to-do",
          "projectId" => "project-a"
        },
        %{
          id: "project-a",
          name: "Project Alpha",
          slug: "alpha",
          repo_url: "git@example.com:alpha/repo.git",
          repo_ref: "main",
          repos: [
            %{key: "backend", repo_url: "git@example.com:alpha/backend.git", default: true},
            %{"key" => "frontend", "repo_url" => "git@example.com:alpha/frontend.git", "workflow_file" => "/opt/frontend/WORKFLOW.md"}
          ],
          workflow_file: "/opt/alpha/WORKFLOW.md"
        }
      )

    assert issue.identifier == "ALPHA-KANEO-7"
    assert issue.tracker_identifier == "KANEO-7"
    assert issue.project_id == "project-a"
    assert issue.project_name == "Project Alpha"
    assert issue.project_slug == "alpha"
    assert issue.project_key == "ALPHA"
    assert issue.source_repo_key == "frontend"
    assert issue.source_repo_url == "git@example.com:alpha/frontend.git"
    assert issue.source_repo_ref == "feature/task-branch"
    assert issue.workflow_file == "/opt/frontend/WORKFLOW.md"
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

  test "covers Kaneo REST helper status handling" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "kaneo",
      tracker_endpoint: "https://kaneo.test/api/",
      tracker_api_token: "token",
      tracker_project_id: "project-a"
    )

    Application.put_env(:symphony_elixir, :kaneo_request_fun, fn opts ->
      send(self(), {:kaneo_request, opts[:method], opts[:url], opts[:json], opts[:headers]})

      case {opts[:method], opts[:url]} do
        {:post, "https://kaneo.test/api/comment/task-ok"} ->
          {:ok, %Req.Response{status: 201, body: %{}}}

        {:post, "https://kaneo.test/api/comment/task-fail"} ->
          {:ok, %Req.Response{status: 422, body: String.duplicate("x", 1_050)}}

        {:post, "https://kaneo.test/api/comment/task-error"} ->
          {:error, :timeout}

        {:put, "https://kaneo.test/api/task/assignee/task-ok"} ->
          {:ok, %Req.Response{status: 200, body: %{}}}

        {:put, "https://kaneo.test/api/task/assignee/task-fail"} ->
          {:ok, %Req.Response{status: 500, body: %{error: "nope"}}}

        {:put, "https://kaneo.test/api/task/assignee/task-error"} ->
          {:error, :closed}

        {:put, "https://kaneo.test/api/task/status/task-ok"} ->
          {:ok, %Req.Response{status: 204, body: ""}}

        {:put, "https://kaneo.test/api/task/status/task-fail"} ->
          {:ok, %Req.Response{status: 409, body: "conflict"}}

        {:put, "https://kaneo.test/api/task/status/task-error"} ->
          {:error, :econnrefused}
      end
    end)

    assert :ok = KaneoClient.create_comment("task-ok", "body")
    assert {:error, {:kaneo_api_status, 422}} = KaneoClient.create_comment("task-fail", "body")
    assert {:error, {:kaneo_api_request, :timeout}} = KaneoClient.create_comment("task-error", "body")

    assert :ok = KaneoClient.assign_issue("task-ok", "user-1")
    assert {:error, {:kaneo_api_status, 500}} = KaneoClient.assign_issue("task-fail", "user-1")
    assert {:error, {:kaneo_api_request, :closed}} = KaneoClient.assign_issue("task-error", "user-1")

    assert :ok = KaneoClient.update_issue_state("task-ok", "in-progress")
    assert {:error, {:kaneo_api_status, 409}} = KaneoClient.update_issue_state("task-fail", "in-progress")
    assert {:error, {:kaneo_api_request, :econnrefused}} = KaneoClient.update_issue_state("task-error", "in-progress")

    assert_receive {:kaneo_request, :post, "https://kaneo.test/api/comment/task-ok", %{content: "body"}, headers}
    assert {"Authorization", "Bearer token"} in headers
  end

  test "covers Kaneo fetch error and config edge cases" do
    previous_kaneo_api_key = System.get_env("KANEO_API_KEY")
    previous_kaneo_project_id = System.get_env("KANEO_PROJECT_ID")

    on_exit(fn ->
      restore_env("KANEO_API_KEY", previous_kaneo_api_key)
      restore_env("KANEO_PROJECT_ID", previous_kaneo_project_id)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "kaneo",
      tracker_endpoint: "https://kaneo.test/api",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_id: nil,
      tracker_active_states: ["to-do", "rework"],
      tracker_terminal_states: ["done"],
      tracker_projects: [
        %{id: "project-a", slug: "alpha"},
        %{id: "project-b", slug: "beta"}
      ]
    )

    Application.put_env(:symphony_elixir, :kaneo_request_fun, fn opts ->
      send(self(), {:kaneo_fetch, opts[:url], opts[:params]})

      cond do
        String.ends_with?(opts[:url], "/task/tasks/project-a") ->
          {:ok, %Req.Response{status: 200, body: [%{"id" => "task-a", "status" => "to-do"}]}}

        String.ends_with?(opts[:url], "/task/tasks/project-b") ->
          {:error, :boom}
      end
    end)

    assert {:error, {:kaneo_api_request, :boom}} = KaneoClient.fetch_candidate_issues()
    assert {:error, {:kaneo_api_request, :boom}} = KaneoClient.fetch_issue_states_by_ids(["task-a"])

    assert_receive {:kaneo_fetch, "https://kaneo.test/api/task/tasks/project-a", [status: "to-do", sortBy: "priority", sortOrder: "asc"]}

    assert_receive {:kaneo_fetch, "https://kaneo.test/api/task/tasks/project-b", [status: "to-do", sortBy: "priority", sortOrder: "asc"]}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "kaneo",
      tracker_api_token: nil,
      tracker_project_id: "project-a"
    )

    System.delete_env("KANEO_API_KEY")
    assert {:error, :missing_kaneo_api_token} = KaneoClient.fetch_candidate_issues()
    assert {:error, :missing_kaneo_api_token} = KaneoClient.request(:get, "/anything")

    System.put_env("KANEO_API_KEY", "token")
    System.delete_env("KANEO_PROJECT_ID")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "kaneo",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_id: nil,
      tracker_projects: nil
    )

    assert {:error, :missing_kaneo_project_id} = KaneoClient.fetch_candidate_issues()
    assert {:ok, []} = KaneoClient.fetch_issues_by_states(["", "   "])

    for endpoint <- [nil, "", "   ", "https://api.linear.app/graphql"] do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "kaneo",
        tracker_endpoint: endpoint,
        tracker_api_token: "token",
        tracker_project_id: "project-a"
      )

      Application.put_env(:symphony_elixir, :kaneo_request_fun, fn opts ->
        send(self(), {:default_endpoint_request, opts[:url]})
        {:ok, %Req.Response{status: 200, body: %{}}}
      end)

      assert {:ok, %Req.Response{status: 200}} = KaneoClient.request(:get, "/ping")
      assert_receive {:default_endpoint_request, "https://cloud.kaneo.app/api/ping"}
    end
  end

  test "covers Kaneo response shape and normalization edges" do
    assert [%{id: "atom-task"}, %{"id" => "string-task"}] =
             KaneoClient.flatten_tasks_response_for_test(%{
               data: %{
                 columns: [
                   %{tasks: [%{id: "atom-task"}]},
                   %{"tasks" => [%{"id" => "string-task"}]},
                   %{}
                 ]
               }
             })

    assert [%{"id" => "task-list"}] =
             KaneoClient.flatten_tasks_response_for_test(%{"tasks" => [%{"id" => "task-list"}]})

    assert [%{id: "atom-list"}] =
             KaneoClient.flatten_tasks_response_for_test(%{tasks: [%{id: "atom-list"}]})

    assert [] = KaneoClient.flatten_tasks_response_for_test(%{unexpected: true})

    issue =
      KaneoClient.normalize_task_for_test(
        %{
          id: "task-id",
          number: "99",
          title: "Atom task",
          description: "repo url: git@example.com:repo.git\nworkflow: /tmp/WORKFLOW.md",
          status: "to-do",
          priority: nil,
          userId: 123,
          createdAt: 42,
          updatedAt: "not-a-date"
        },
        %{
          id: "project-a",
          name: " ",
          slug: " ",
          repo_url: "",
          repo_ref: "",
          workflow_file: "",
          assignee: "user-1"
        }
      )

    assert issue.identifier == "PROJECT-A-KANEO-99"
    assert issue.source_repo_url == "git@example.com:repo.git"
    assert issue.workflow_file == "/tmp/WORKFLOW.md"
    assert issue.priority == nil
    assert issue.assignee_id == 123
    refute issue.assigned_to_worker
    assert issue.created_at == nil
    assert issue.updated_at == nil

    blank_assignee_issue =
      KaneoClient.normalize_task_for_test(
        %{"id" => "blank-assignee", "userId" => "anyone"},
        %{id: "project-a", assignee: " "}
      )

    assert blank_assignee_issue.assigned_to_worker

    legacy_issue =
      KaneoClient.normalize_task_for_test(%{"id" => "legacy-task", "title" => "Legacy"}, %{legacy?: true})

    assert legacy_issue.identifier == "legacy-task"
    assert legacy_issue.project_key == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "kaneo",
      tracker_endpoint: "https://kaneo.test/api",
      tracker_api_token: "token",
      tracker_project_id: "project-a"
    )

    Application.put_env(:symphony_elixir, :kaneo_request_fun, fn _opts ->
      {:ok, %Req.Response{status: 200, body: [nil]}}
    end)

    assert {:ok, []} = KaneoClient.fetch_candidate_issues()
  end
end

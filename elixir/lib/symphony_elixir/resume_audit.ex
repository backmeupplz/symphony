defmodule SymphonyElixir.ResumeAudit do
  @moduledoc """
  Builds a read-only restart/resume audit from tracker-backed active work.
  """

  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @type workspace_check :: %{
          worker_host: String.t() | nil,
          path: Path.t() | nil,
          exists?: boolean() | :unknown,
          error: term() | nil
        }

  @type entry :: %{
          issue_id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          state: String.t() | nil,
          project_key: String.t() | nil,
          tracker_identifier: String.t() | nil,
          source_repo_key: String.t() | nil,
          source_repo_url: String.t() | nil,
          workspace_checks: [workspace_check()],
          resume_action: String.t()
        }

  @spec entries(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def entries(opts \\ []) do
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_candidate_issues/0)
    worker_hosts = Keyword.get(opts, :worker_hosts, Config.settings!().worker.ssh_hosts)
    workspace_exists? = Keyword.get(opts, :workspace_exists?, &File.dir?/1)

    case issue_fetcher.() do
      {:ok, issues} when is_list(issues) ->
        {:ok, Enum.map(issues, &entry_for_issue(&1, worker_hosts, workspace_exists?))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec format_report([entry()]) :: String.t()
  def format_report(entries) when is_list(entries) do
    active_states = Config.active_execution_state_names() |> Enum.sort() |> Enum.join(", ")

    header = [
      "Symphony restart/resume audit",
      "Source of truth: tracker tasks in active states (#{active_states}) plus preserved workspaces.",
      ""
    ]

    body =
      case entries do
        [] ->
          ["No active task-backed work found."]

        entries ->
          Enum.map(entries, &format_entry/1)
      end

    (header ++ body)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp entry_for_issue(%Issue{} = issue, worker_hosts, workspace_exists?) do
    workspace_checks =
      worker_hosts
      |> workspace_check_hosts()
      |> Enum.map(&workspace_check(issue, &1, workspace_exists?))

    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      project_key: issue.project_key,
      tracker_identifier: issue.tracker_identifier,
      source_repo_key: issue.source_repo_key,
      source_repo_url: issue.source_repo_url,
      workspace_checks: workspace_checks,
      resume_action: resume_action(workspace_checks)
    }
  end

  defp entry_for_issue(issue, worker_hosts, workspace_exists?) do
    issue
    |> normalize_issue()
    |> entry_for_issue(worker_hosts, workspace_exists?)
  end

  defp normalize_issue(issue) when is_map(issue) do
    %Issue{
      id: Map.get(issue, :id) || Map.get(issue, "id"),
      identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      title: Map.get(issue, :title) || Map.get(issue, "title"),
      state: Map.get(issue, :state) || Map.get(issue, "state")
    }
  end

  defp normalize_issue(issue), do: %Issue{identifier: inspect(issue)}

  defp workspace_check_hosts([]), do: [nil]
  defp workspace_check_hosts(worker_hosts) when is_list(worker_hosts), do: worker_hosts
  defp workspace_check_hosts(_worker_hosts), do: [nil]

  defp workspace_check(%Issue{} = issue, worker_host, workspace_exists?) do
    case Workspace.path_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        %{
          worker_host: worker_host,
          path: workspace,
          exists?: workspace_exists_for_host?(workspace, worker_host, workspace_exists?),
          error: nil
        }

      {:error, reason} ->
        %{worker_host: worker_host, path: nil, exists?: false, error: reason}
    end
  end

  defp workspace_exists_for_host?(_workspace, worker_host, _workspace_exists?) when is_binary(worker_host),
    do: :unknown

  defp workspace_exists_for_host?(workspace, nil, workspace_exists?) when is_function(workspace_exists?, 1),
    do: workspace_exists?.(workspace)

  defp resume_action(workspace_checks) do
    cond do
      Enum.any?(workspace_checks, &(&1.exists? == true)) ->
        "resume preserved workspace"

      Enum.any?(workspace_checks, &(&1.exists? == :unknown)) ->
        "redispatch active task; remote workspace presence unchecked"

      true ->
        "dispatch active task into a workspace"
    end
  end

  defp format_entry(entry) do
    workspace_summary =
      entry.workspace_checks
      |> Enum.map_join("; ", &format_workspace_check/1)

    "- #{entry.identifier || entry.issue_id || "unknown"} [#{entry.state || "unknown"}] #{entry.title || "(untitled)"}\n" <>
      "  action: #{entry.resume_action}\n" <>
      "  workspace: #{workspace_summary}"
  end

  defp format_workspace_check(%{worker_host: worker_host, path: path, exists?: exists?, error: nil}) do
    host = worker_host || "local"
    exists = format_exists(exists?)
    "#{host}: #{path} exists=#{exists}"
  end

  defp format_workspace_check(%{worker_host: worker_host, error: reason}) do
    host = worker_host || "local"
    "#{host}: error=#{inspect(reason)}"
  end

  defp format_exists(true), do: "yes"
  defp format_exists(false), do: "no"
  defp format_exists(:unknown), do: "unknown"
end

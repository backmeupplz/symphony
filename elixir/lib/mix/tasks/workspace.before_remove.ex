defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  @shortdoc "Clean up GitHub PRs and merged branches before workspace removal"

  @moduledoc """
  Closes open pull requests for the current Git branch, and deletes the remote
  branch when GitHub reports that the branch belongs to a merged pull request.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --repo openai/symphony
      mix workspace.before_remove --reconcile-merged --limit 50

  `--reconcile-merged` scans a bounded set of recent merged pull requests and
  deletes lingering same-repository head branches when the branch is not default,
  protected, from a fork, or still associated with an open same-repository PR.
  """

  @fallback_repo "openai/symphony"
  @pr_json_fields "number,headRefName,headRepository,headRepositoryOwner,isCrossRepository"
  @default_reconcile_limit 50

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, limit: :integer, reconcile_merged: :boolean, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        repo = opts[:repo] || current_repo() || @fallback_repo
        branch = opts[:branch] || current_branch()

        if opts[:reconcile_merged] do
          reconcile_merged_branches(repo, opts[:limit] || @default_reconcile_limit)
        else
          maybe_close_open_pull_requests(repo, branch)
        end
    end
  end

  defp maybe_close_open_pull_requests(_repo, nil), do: :ok

  defp maybe_close_open_pull_requests(repo, branch) do
    if gh_available?() and gh_authenticated?() do
      open_pr_numbers = list_pull_request_numbers(repo, branch, "open")

      Enum.each(open_pr_numbers, &close_pull_request(repo, branch, &1))
      maybe_delete_merged_branch(repo, branch, open_pr_numbers)
    end

    :ok
  end

  defp gh_available? do
    not is_nil(System.find_executable("gh"))
  end

  defp gh_authenticated? do
    match?({:ok, _output}, run_command("gh", ["auth", "status"]))
  end

  defp list_pull_request_numbers(repo, branch, state) do
    case run_command("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           state,
           "--json",
           "number",
           "--jq",
           ".[].number"
         ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp maybe_delete_merged_branch(_repo, _branch, [_pr_number | _rest]), do: :ok

  defp maybe_delete_merged_branch(repo, branch, []) do
    case list_pull_requests(repo, state: "merged", head: branch) do
      [] ->
        :ok

      merged_prs ->
        delete_merged_branch_if_safe(repo, branch, merged_prs)
    end
  end

  defp delete_merged_branch_if_safe(repo, branch, merged_prs) do
    same_repo_prs = Enum.filter(merged_prs, &same_repo_head?(&1, repo, branch))

    if same_repo_prs == [] do
      Mix.shell().info("Skipped deleting remote branch #{branch}: merged PR head is from a fork or different repository")
    else
      do_delete_merged_branch_if_safe(repo, branch, same_repo_prs)
    end
  end

  defp do_delete_merged_branch_if_safe(repo, branch, merged_prs) do
    case branch_deletion_safety(repo, branch) do
      :safe ->
        delete_remote_branch(repo, branch, merged_prs)

      {:skip, :already_deleted} ->
        Mix.shell().info("Skipped deleting remote branch #{branch}: remote branch already deleted")

      {:skip, reason} ->
        Mix.shell().error("Skipped deleting remote branch #{branch}: #{reason}")
    end
  end

  defp branch_deletion_safety(_repo, branch) when branch in ["main", "master", "trunk", "develop", "dev"] do
    {:skip, "protected/default branch name"}
  end

  defp branch_deletion_safety(repo, branch) do
    with :not_default <- default_branch_status(repo, branch),
         :not_protected <- protected_branch_status(repo, branch) do
      :safe
    else
      :default -> {:skip, "default branch"}
      :protected -> {:skip, "protected branch"}
      :missing -> {:skip, :already_deleted}
      {:unknown, check} -> {:skip, "could not verify #{check}"}
    end
  end

  defp default_branch_status(repo, branch) do
    case run_command("gh", ["repo", "view", repo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]) do
      {:ok, output} ->
        if String.trim(output) == branch, do: :default, else: :not_default

      {:error, _reason} ->
        {:unknown, "default branch"}
    end
  end

  defp protected_branch_status(repo, branch) do
    case run_command("gh", ["api", "repos/#{repo}/branches/#{encode_path_segment(branch)}", "--jq", ".protected"]) do
      {:ok, output} ->
        if String.trim(output) == "true", do: :protected, else: :not_protected

      {:error, {_status, output}} ->
        if missing_branch_output?(output), do: :missing, else: {:unknown, "branch protection"}
    end
  end

  defp delete_remote_branch(repo, branch, merged_prs) do
    case run_command("gh", ["api", "--method", "DELETE", "repos/#{repo}/git/refs/heads/#{branch}"]) do
      {:ok, _output} ->
        Mix.shell().info("Deleted remote branch #{branch} after merged PR #{format_pr_numbers(merged_prs)}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        if status == 1 and missing_branch_output?(trimmed_output) do
          Mix.shell().info("Skipped deleting remote branch #{branch}: remote branch already deleted")
        else
          Mix.shell().error("Failed to delete remote branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
        end
    end
  end

  defp reconcile_merged_branches(repo, limit) when is_integer(limit) and limit > 0 do
    if gh_available?() and gh_authenticated?() do
      repo
      |> list_pull_requests(state: "merged", limit: limit)
      |> Enum.group_by(&Map.get(&1, "headRefName"))
      |> Enum.each(&reconcile_merged_branch_group(repo, &1))
    end

    :ok
  end

  defp reconcile_merged_branches(_repo, _limit), do: :ok

  defp reconcile_merged_branch_group(repo, {branch, prs}) when is_binary(branch) and branch != "" do
    if branch_has_same_repo_open_pr?(repo, branch) do
      Mix.shell().error("Skipped deleting remote branch #{branch}: branch still has an open pull request")
    else
      delete_merged_branch_if_safe(repo, branch, prs)
    end
  end

  defp reconcile_merged_branch_group(_repo, {_branch, _prs}), do: :ok

  defp branch_has_same_repo_open_pr?(repo, branch) do
    repo
    |> list_pull_requests(state: "open", head: branch)
    |> Enum.any?(&same_repo_head?(&1, repo, branch))
  end

  defp list_pull_requests(repo, opts) do
    state = Keyword.fetch!(opts, :state)
    head = Keyword.get(opts, :head)
    limit = Keyword.get(opts, :limit)

    args =
      ["pr", "list", "--repo", repo]
      |> maybe_append_head(head)
      |> Kernel.++(["--state", state, "--json", @pr_json_fields])
      |> maybe_append_limit(limit)

    case run_command("gh", args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, prs} when is_list(prs) -> prs
          _ -> []
        end

      {:error, _reason} ->
        []
    end
  end

  defp maybe_append_head(args, head) when is_binary(head) and head != "", do: args ++ ["--head", head]
  defp maybe_append_head(args, _head), do: args

  defp maybe_append_limit(args, limit) when is_integer(limit) and limit > 0, do: args ++ ["--limit", Integer.to_string(limit)]
  defp maybe_append_limit(args, _limit), do: args

  defp same_repo_head?(pr, repo, branch) when is_map(pr) and is_binary(repo) do
    Map.get(pr, "headRefName") == branch and Map.get(pr, "isCrossRepository") != true and
      normalize_repo_name(head_repo_name(pr)) == normalize_repo_name(repo)
  end

  defp same_repo_head?(_pr, _repo, _branch), do: false

  defp head_repo_name(pr) do
    case Map.get(pr, "headRepository") do
      %{"nameWithOwner" => name_with_owner} when is_binary(name_with_owner) and name_with_owner != "" ->
        name_with_owner

      %{"owner" => %{"login" => owner}, "name" => name} when is_binary(owner) and is_binary(name) ->
        owner <> "/" <> name

      %{"name" => name} when is_binary(name) ->
        owner = get_in(pr, ["headRepositoryOwner", "login"])
        if is_binary(owner), do: owner <> "/" <> name, else: nil

      _ ->
        nil
    end
  end

  defp normalize_repo_name(repo) when is_binary(repo) do
    repo
    |> String.trim()
    |> String.trim_trailing(".git")
    |> String.downcase()
  end

  defp normalize_repo_name(_repo), do: nil

  defp missing_branch_output?(output) when is_binary(output) do
    normalized = String.downcase(output)
    String.contains?(normalized, "not found") or String.contains?(normalized, "http 404")
  end

  defp encode_path_segment(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp format_pr_numbers(prs), do: prs |> Enum.map_join(", ", &"##{Map.get(&1, "number")}")

  defp close_pull_request(repo, branch, pr_number) do
    case run_command("gh", [
           "pr",
           "close",
           pr_number,
           "--repo",
           repo,
           "--comment",
           closing_comment(branch)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp closing_comment(branch) do
    "Closing because the Linear issue for branch #{branch} entered a terminal state without merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp current_branch do
    case run_command("git", ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp current_repo do
    with {:ok, output} <- run_command("git", ["remote", "get-url", "origin"]),
         repo when is_binary(repo) <- repo_name_from_remote_url(String.trim(output)) do
      repo
    else
      _ -> nil
    end
  end

  defp repo_name_from_remote_url(""), do: nil

  defp repo_name_from_remote_url(url) do
    case Regex.run(~r{github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$}, url) do
      [_url, _owner, _repo] = match ->
        match |> Enum.drop(1) |> Enum.join("/")

      _ ->
        nil
    end
  end

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end

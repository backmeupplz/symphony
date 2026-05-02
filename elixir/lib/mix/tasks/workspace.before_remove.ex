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
  """

  @default_repo "openai/symphony"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        repo = opts[:repo] || @default_repo
        branch = opts[:branch] || current_branch()

        maybe_close_open_pull_requests(repo, branch)
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
    case list_pull_request_numbers(repo, branch, "merged") do
      [] ->
        :ok

      merged_pr_numbers ->
        delete_merged_branch_if_safe(repo, branch, merged_pr_numbers)
    end
  end

  defp delete_merged_branch_if_safe(repo, branch, merged_pr_numbers) do
    case branch_deletion_safety(repo, branch) do
      :safe ->
        delete_remote_branch(repo, branch, merged_pr_numbers)

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

      {:error, _reason} ->
        {:unknown, "branch protection"}
    end
  end

  defp delete_remote_branch(repo, branch, merged_pr_numbers) do
    case run_command("gh", ["api", "--method", "DELETE", "repos/#{repo}/git/refs/heads/#{branch}"]) do
      {:ok, _output} ->
        Mix.shell().info("Deleted remote branch #{branch} after merged PR #{format_pr_numbers(merged_pr_numbers)}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to delete remote branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp encode_path_segment(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp format_pr_numbers(numbers), do: numbers |> Enum.map_join(", ", &"##{&1}")

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

defmodule Mix.Tasks.Workspace.BeforeRemoveTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workspace.BeforeRemove

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("workspace.before_remove")
    :ok
  end

  test "prints help" do
    output =
      capture_io(fn ->
        BeforeRemove.run(["--help"])
      end)

    assert output =~ "mix workspace.before_remove"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      BeforeRemove.run(["--wat"])
    end
  end

  test "no-ops when branch is unavailable" do
    with_path([], fn ->
      in_temp_dir(fn ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""
      end)
    end)
  end

  test "no-ops when gh is unavailable" do
    with_path([], fn ->
      output =
        capture_io(fn ->
          BeforeRemove.run(["--branch", "feature/no-gh", "--repo", "openai/symphony"])
        end)

      assert output == ""
    end)
  end

  test "uses current branch for lookup when branch option is omitted" do
    with_fake_gh_and_git(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '101\n102\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "101" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
        printf 'boom\n' >&2
        exit 17
      fi

      exit 99
      """,
      """
      #!/bin/sh
      printf 'feature/workpad\n'
      exit 0
      """,
      fn log_path ->
        {output, error_output} =
          capture_task_output(fn ->
            BeforeRemove.run([])
          end)

        assert output =~ "Closed PR #101 for branch feature/workpad"
        assert error_output =~ "Failed to close PR #102 for branch feature/workpad"

        log = File.read!(log_path)

        assert log =~
                 "pr list --repo openai/symphony --head feature/workpad --state open --json number --jq .[].number"

        assert log =~ "pr close 101 --repo openai/symphony"
        assert log =~ "pr close 102 --repo openai/symphony"
      end
    )
  end

  test "closes open pull requests for the branch and tolerates close failures" do
    with_fake_gh(fn log_path ->
      File.write!(log_path, "")

      {output, error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--branch", "feature/workpad", "--repo", "openai/symphony"])
        end)

      assert output =~ "Closed PR #101 for branch feature/workpad"
      assert error_output =~ "Failed to close PR #102 for branch feature/workpad"

      log = File.read!(log_path)

      assert log =~ "auth status"
      assert log =~ "pr list --repo openai/symphony --head feature/workpad --state open --json number --jq .[].number"
      assert log =~ "pr close 101 --repo openai/symphony"
      assert log =~ "pr close 102 --repo openai/symphony"
      refute log =~ "api --method DELETE"

      {second_output, error_output} =
        capture_task_output(fn ->
          Mix.Task.reenable("workspace.before_remove")
          BeforeRemove.run(["--branch", "feature/workpad", "--repo", "openai/symphony"])
        end)

      assert second_output =~ "Closed PR #101 for branch feature/workpad"
      assert error_output =~ "Failed to close PR #102 for branch feature/workpad"
    end)
  end

  test "formats close failures without command stderr output" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '102\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
        exit 17
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            Mix.Task.reenable("workspace.before_remove")
            BeforeRemove.run(["--branch", "feature/no-output", "--repo", "openai/symphony"])
          end)

        assert error_output =~ "Failed to close PR #102 for branch feature/no-output: exit 17"
        refute error_output =~ "output="
        log = File.read!(log_path)
        assert log =~ "pr list --repo openai/symphony --head feature/no-output --state open --json number --jq .[].number"
        assert log =~ "pr close 102 --repo openai/symphony"
      end
    )
  end

  test "deletes the remote branch when the branch only has merged pull requests" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":201,"headRefName":"feature/merged","headRepository":{"name":"symphony","nameWithOwner":""},"headRepositoryOwner":{"login":"openai"},"isCrossRepository":false},{"number":202,"headRefName":"feature/merged","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'main\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/openai/symphony/branches/feature%2Fmerged" ]; then
        printf 'false\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "DELETE" ]; then
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/merged", "--repo", "openai/symphony"])
          end)

        assert output =~ "Deleted remote branch feature/merged after merged PR #201, #202"

        log = File.read!(log_path)
        assert log =~ "pr list --repo openai/symphony --head feature/merged --state open"
        assert log =~ "pr list --repo openai/symphony --head feature/merged --state merged"
        assert log =~ "repo view openai/symphony --json defaultBranchRef --jq .defaultBranchRef.name"
        assert log =~ "api repos/openai/symphony/branches/feature%2Fmerged --jq .protected"
        assert log =~ "api --method DELETE repos/openai/symphony/git/refs/heads/feature/merged"
      end
    )
  end

  test "uses the origin remote repository when repo option is omitted" do
    with_fake_gh_and_git(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 0
      fi

      exit 99
      """,
      """
      #!/bin/sh
      if [ "$1" = "remote" ] && [ "$2" = "get-url" ] && [ "$3" = "origin" ]; then
        printf 'git@github.com:backmeupplz/symphony.git\n'
        exit 0
      fi

      if [ "$1" = "branch" ] && [ "$2" = "--show-current" ]; then
        printf 'feature/repo-detect\n'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log =~ "pr list --repo backmeupplz/symphony --head feature/repo-detect --state open"
        assert log =~ "pr list --repo backmeupplz/symphony --head feature/repo-detect --state merged"
      end
    )
  end

  test "skips fork merged pull request branches" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":901,"headRefName":"feature/fork","headRepository":{"nameWithOwner":"someone/symphony"},"isCrossRepository":true}]'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/fork", "--repo", "openai/symphony"])
          end)

        assert output =~ "Skipped deleting remote branch feature/fork: merged PR head is from a fork or different repository"

        log = File.read!(log_path)
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "treats an already-deleted remote branch as a safe skip" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":902,"headRefName":"feature/gone","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'main\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/openai/symphony/branches/feature%2Fgone" ]; then
        printf 'HTTP 404: Not Found\n' >&2
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/gone", "--repo", "openai/symphony"])
          end)

        assert output =~ "Skipped deleting remote branch feature/gone: remote branch already deleted"

        log = File.read!(log_path)
        assert log =~ "api repos/openai/symphony/branches/feature%2Fgone --jq .protected"
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "treats a delete-time missing branch as a safe race" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":903,"headRefName":"feature/race","headRepository":{"owner":{"login":"openai"},"name":"symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'main\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/openai/symphony/branches/feature%2Frace" ]; then
        printf 'false\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "DELETE" ]; then
        printf 'HTTP 404: Not Found\n' >&2
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/race", "--repo", "openai/symphony"])
          end)

        assert output =~ "Skipped deleting remote branch feature/race: remote branch already deleted"

        log = File.read!(log_path)
        assert log =~ "api --method DELETE repos/openai/symphony/git/refs/heads/feature/race"
      end
    )
  end

  test "skips malformed or incomplete merged pull request metadata" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[null,{"number":904,"headRefName":"feature/no-repo","headRepository":null,"isCrossRepository":false}]'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/no-repo", "--repo", "openai/symphony"])
          end)

        assert output =~ "Skipped deleting remote branch feature/no-repo: merged PR head is from a fork or different repository"

        log = File.read!(log_path)
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "skips branch deletion for protected default branch names" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":301,"headRefName":"main","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "main", "--repo", "openai/symphony"])
          end)

        assert error_output =~ "Skipped deleting remote branch main: protected/default branch name"

        log = File.read!(log_path)
        assert log =~ "pr list --repo openai/symphony --head main --state merged"
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "skips branch deletion when branch protection cannot be verified" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":401,"headRefName":"feature/unknown","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'main\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/openai/symphony/branches/feature%2Funknown" ]; then
        printf 'api unavailable\n' >&2
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "feature/unknown", "--repo", "openai/symphony"])
          end)

        assert error_output =~ "Skipped deleting remote branch feature/unknown: could not verify branch protection"

        log = File.read!(log_path)
        assert log =~ "api repos/openai/symphony/branches/feature%2Funknown --jq .protected"
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "skips branch deletion when the branch is the repository default branch" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":501,"headRefName":"release/current","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'release/current\n'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "release/current", "--repo", "openai/symphony"])
          end)

        assert error_output =~ "Skipped deleting remote branch release/current: default branch"

        log = File.read!(log_path)
        assert log =~ "repo view openai/symphony --json defaultBranchRef --jq .defaultBranchRef.name"
        refute log =~ "branches/release%2Fcurrent"
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "skips branch deletion when default branch cannot be verified" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":601,"headRefName":"feature/default-unknown","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'repo unavailable\n' >&2
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "feature/default-unknown", "--repo", "openai/symphony"])
          end)

        assert error_output =~ "Skipped deleting remote branch feature/default-unknown: could not verify default branch"

        log = File.read!(log_path)
        assert log =~ "repo view openai/symphony --json defaultBranchRef --jq .defaultBranchRef.name"
        refute log =~ "branches/feature%2Fdefault-unknown"
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "skips branch deletion when GitHub reports branch protection" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":701,"headRefName":"release/protected","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'main\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/openai/symphony/branches/release%2Fprotected" ]; then
        printf 'true\n'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "release/protected", "--repo", "openai/symphony"])
          end)

        assert error_output =~ "Skipped deleting remote branch release/protected: protected branch"

        log = File.read!(log_path)
        assert log =~ "api repos/openai/symphony/branches/release%2Fprotected --jq .protected"
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "reports remote branch deletion failures without aborting cleanup" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "merged" ]; then
        printf '%s\n' '[{"number":801,"headRefName":"feature/delete-fails","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false},{"number":802,"headRefName":"feature/delete-fails","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'main\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/openai/symphony/branches/feature%2Fdelete-fails" ]; then
        printf 'false\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "DELETE" ]; then
        printf 'branch is protected\n' >&2
        exit 22
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "feature/delete-fails", "--repo", "openai/symphony"])
          end)

        assert error_output =~
                 "Failed to delete remote branch feature/delete-fails: exit 22 output=\"branch is protected\""

        log = File.read!(log_path)
        assert log =~ "api --method DELETE repos/openai/symphony/git/refs/heads/feature/delete-fails"
      end
    )
  end

  test "reconciles lingering merged same-repo branches with bounded safe skips" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$6" = "merged" ]; then
        printf '%s\n' '[{"number":910,"headRefName":"feature/reconcile","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false},{"number":911,"headRefName":"feature/fork-reconcile","headRepository":{"nameWithOwner":"someone/symphony"},"isCrossRepository":true},{"number":912,"headRefName":"feature/open-reconcile","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ] && [ "$6" = "feature/open-reconcile" ]; then
        printf '%s\n' '[{"number":913,"headRefName":"feature/open-reconcile","headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$8" = "open" ]; then
        printf '[]\n'
        exit 0
      fi

      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'main\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/openai/symphony/branches/feature%2Freconcile" ]; then
        printf 'false\n'
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "DELETE" ]; then
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        {output, error_output} =
          capture_task_output(fn ->
            BeforeRemove.run(["--reconcile-merged", "--limit", "3", "--repo", "openai/symphony"])
          end)

        assert output =~ "Deleted remote branch feature/reconcile after merged PR #910"
        assert output =~ "Skipped deleting remote branch feature/fork-reconcile: merged PR head is from a fork or different repository"
        assert error_output =~ "Skipped deleting remote branch feature/open-reconcile: branch still has an open pull request"

        log = File.read!(log_path)
        assert log =~ "pr list --repo openai/symphony --state merged"
        assert log =~ "--limit 3"
        assert log =~ "api --method DELETE repos/openai/symphony/git/refs/heads/feature/reconcile"
        refute log =~ "git/refs/heads/feature/fork-reconcile"
        refute log =~ "git/refs/heads/feature/open-reconcile"
      end
    )
  end

  test "reconcile ignores invalid limits and malformed branch groups" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$6" = "merged" ]; then
        printf '%s\n' '[{"number":920,"headRefName":null,"headRepository":{"nameWithOwner":"openai/symphony"},"isCrossRepository":false}]'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--reconcile-merged", "--limit", "1", "--repo", "openai/symphony"])
          end)

        assert output == ""

        Mix.Task.reenable("workspace.before_remove")

        invalid_limit_output =
          capture_io(fn ->
            BeforeRemove.run(["--reconcile-merged", "--limit", "0", "--repo", "openai/symphony"])
          end)

        assert invalid_limit_output == ""

        log = File.read!(log_path)
        assert log =~ "pr list --repo openai/symphony --state merged"
        refute log =~ "api --method DELETE"
      end
    )
  end

  test "no-ops when PR list fails for current branch" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/list-fails", "--repo", "openai/symphony"])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log =~ "auth status"

        assert log =~
                 "pr list --repo openai/symphony --head feature/list-fails --state open --json number --jq .[].number"

        refute log =~ "pr close"
      end
    )
  end

  test "no-ops when git current branch is blank" do
    with_fake_gh_and_git(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      exit 99
      """,
      """
      #!/bin/sh
      printf '\n'
      exit 0
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log == ""
        refute log =~ "pr list"
      end
    )
  end

  test "no-ops when gh auth is unavailable" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"
      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 1
      fi
      exit 99
      """,
      fn log_path ->
        BeforeRemove.run(["--branch", "feature/no-auth", "--repo", "openai/symphony"])

        log = File.read!(log_path)
        assert log =~ "auth status"
        refute log =~ "pr list"
      end
    )
  end

  defp with_fake_gh(fun) do
    with_fake_binaries(
      %{
        "gh" => """
        #!/bin/sh
        printf '%s\n' "$*" >> "$GH_LOG"

        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          exit 0
        fi

        if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
          printf '101\n102\n'
          exit 0
        fi

        if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "101" ]; then
          exit 0
        fi

        if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
          printf 'boom\n' >&2
          exit 17
        fi

        exit 99
        """
      },
      fun
    )
  end

  defp with_fake_gh(script, fun) do
    with_fake_binaries(%{"gh" => script}, fun)
  end

  defp with_fake_gh_and_git(gh_script, git_script, fun) do
    with_fake_binaries(%{"gh" => gh_script, "git" => git_script}, fun)
  end

  defp with_fake_binaries(scripts, fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-task-test-#{unique}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "gh.log")

    try do
      File.rm_rf!(root)
      File.mkdir_p!(bin_dir)
      File.write!(log_path, "")
      original_path = System.get_env("PATH") || ""
      path_with_binaries = Enum.join([bin_dir, original_path], ":")

      Enum.each(scripts, fn {name, script} ->
        path = Path.join(bin_dir, name)
        File.write!(path, script)
        File.chmod!(path, 0o755)
      end)

      with_env(
        %{
          "GH_LOG" => log_path,
          "PATH" => path_with_binaries
        },
        fn ->
          fun.(log_path)
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  defp with_path(paths, fun) do
    with_env(%{"PATH" => Enum.join(paths, ":")}, fun)
  end

  defp with_env(overrides, fun) do
    keys = Map.keys(overrides)
    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp in_temp_dir(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-empty-dir-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp capture_task_output(fun) do
    parent = self()
    ref = make_ref()

    error_output =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            fun.()
          end)

        send(parent, {ref, output})
      end)

    output =
      receive do
        {^ref, output} -> output
      after
        1_000 -> flunk("Timed out waiting for captured task output")
      end

    {output, error_output}
  end
end

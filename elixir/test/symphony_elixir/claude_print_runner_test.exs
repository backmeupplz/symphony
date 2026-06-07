defmodule SymphonyElixir.ClaudePrintRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.PrintRunner

  test "runs claude print mode with configured model effort and env file" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-runner-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE")
      claude_binary = Path.join(test_root, "fake-claude")
      env_file = Path.join(test_root, "anthropic.env")
      trace_file = Path.join(test_root, "claude.trace")

      File.mkdir_p!(workspace)
      File.write!(env_file, "export ANTHROPIC_API_KEY='test-key'\n")

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' "$@" > #{trace_file}
      printf 'key=%s\\n' "$ANTHROPIC_API_KEY" >> #{trace_file}
      printf 'claude completed'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary,
        claude_model: "claude-opus-4-8",
        claude_effort: "high",
        claude_permission_mode: "bypassPermissions",
        claude_env_file: env_file
      )

      issue = %Issue{
        id: "issue-claude",
        identifier: "MT-CLAUDE",
        title: "Use Claude",
        description: "Run print mode",
        state: "In Progress"
      }

      assert {:ok, result} = PrintRunner.run(workspace, "Do the work", issue)
      assert result.result == "claude completed"

      trace = File.read!(trace_file)
      assert trace =~ "--print\n--model\nclaude-opus-4-8\n--effort\nhigh"
      refute trace =~ "--bare"
      assert trace =~ "--permission-mode\nbypassPermissions\nDo the work"
      assert trace =~ "key=test-key"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner can route work to claude backend" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-agent-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-agent.trace")

      File.mkdir_p!(workspace_root)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' "$@" > #{trace_file}
      printf 'done'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-agent-claude",
        identifier: "MT-AGENT-CLAUDE",
        title: "Route to Claude",
        description: "Use Claude backend",
        state: "Done"
      }

      assert :ok = AgentRunner.run(issue, self(), max_turns: 1, issue_state_fetcher: fn _ids -> {:ok, []} end)
      assert File.read!(trace_file) =~ "You are an agent for this repository."
    after
      File.rm_rf(test_root)
    end
  end
end

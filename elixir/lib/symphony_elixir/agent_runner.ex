defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured coding agent.
  """

  require Logger
  alias SymphonyElixir.Claude.PrintRunner
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, RequirementsContext, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    # Deterministically reflect that the ticket is now being worked, regardless of
    # what the coding agent does. Best-effort: a tracker failure never blocks work.
    maybe_mark_issue_in_progress(issue)

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp maybe_mark_issue_in_progress(%Issue{id: issue_id, state: state} = issue) when is_binary(issue_id) do
    case Config.in_progress_state_name() do
      nil ->
        :ok

      in_progress ->
        if normalized_state(state) == normalized_state(in_progress) do
          :ok
        else
          case Tracker.update_issue_state(issue_id, in_progress) do
            :ok ->
              Logger.info("Marked #{issue_context(issue)} as #{in_progress} on dispatch")

            {:error, reason} ->
              Logger.warning("Could not mark #{issue_context(issue)} as #{in_progress} on dispatch: #{inspect(reason)}")
          end

          :ok
        end
    end
  end

  defp maybe_mark_issue_in_progress(_issue), do: :ok

  defp normalized_state(nil), do: nil
  defp normalized_state(state) when is_binary(state), do: SymphonyElixir.Config.Schema.normalize_issue_state(state)

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp requirements_result_handler(recipient, %Issue{id: issue_id})
       when is_binary(issue_id) and is_pid(recipient) do
    fn result ->
      send(recipient, {:requirements_revision_result, issue_id, result})
      :ok
    end
  end

  defp requirements_result_handler(_recipient, _issue), do: fn _result -> :ok end

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    requirements_revision = RequirementsContext.revision(issue)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        turn_context = %{
          app_session: session,
          workspace: workspace,
          codex_update_recipient: codex_update_recipient,
          opts: opts,
          issue_state_fetcher: issue_state_fetcher,
          max_turns: max_turns
        }

        do_run_codex_turns(turn_context, issue, 1, requirements_revision, nil)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    case Config.settings!().agent.backend do
      "claude" -> run_claude_turns(workspace, issue, codex_update_recipient, opts, worker_host)
      _ -> run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp run_claude_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    # One stable session id for the whole run so continuation turns resume the same
    # Claude conversation (matches Codex's persistent app-server session).
    claude_session_id = uuid4()
    requirements_revision = RequirementsContext.revision(issue)

    turn_context = %{
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      worker_host: worker_host,
      max_turns: max_turns,
      claude_session_id: claude_session_id
    }

    do_run_claude_turns(turn_context, issue, 1, requirements_revision, nil)
  end

  defp do_run_claude_turns(
         turn_context,
         issue,
         turn_number,
         requirements_revision,
         prompt_override
       ) do
    prompt =
      prompt_override ||
        build_turn_prompt(issue, turn_context.opts, turn_number, turn_context.max_turns)

    with {:ok, turn_session} <-
           PrintRunner.run(
             turn_context.workspace,
             prompt,
             issue,
             on_message: codex_message_handler(turn_context.codex_update_recipient, issue),
             worker_host: turn_context.worker_host,
             session_id: turn_context.claude_session_id,
             resume: turn_number > 1
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}")

      case continue_with_issue?(
             issue,
             turn_context.issue_state_fetcher,
             requirements_revision
           ) do
        {:reconcile, refreshed_issue, refreshed_revision}
        when turn_number < turn_context.max_turns ->
          Logger.info("Forcing requirements reconciliation for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{turn_context.max_turns}")

          do_run_claude_turns(
            turn_context,
            refreshed_issue,
            turn_number + 1,
            refreshed_revision,
            RequirementsContext.steer_prompt(refreshed_issue, RequirementsContext.context(issue))
          )

        {:reconcile, refreshed_issue, refreshed_revision} ->
          {:error, {:requirements_stale_at_max_turns, refreshed_issue.id, requirements_revision, refreshed_revision}}

        {:continue, refreshed_issue} when turn_number < turn_context.max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{turn_context.max_turns}")

          do_run_claude_turns(
            turn_context,
            refreshed_issue,
            turn_number + 1,
            requirements_revision,
            nil
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_run_codex_turns(
         turn_context,
         issue,
         turn_number,
         requirements_revision,
         prompt_override
       ) do
    prompt =
      prompt_override ||
        build_turn_prompt(issue, turn_context.opts, turn_number, turn_context.max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             turn_context.app_session,
             prompt,
             issue,
             on_message: codex_message_handler(turn_context.codex_update_recipient, issue),
             on_requirements_result: requirements_result_handler(turn_context.codex_update_recipient, issue),
             requirements_revision: requirements_revision
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}")

      delivered_revision = turn_session[:requirements_revision] || requirements_revision

      case continue_with_issue?(
             issue,
             turn_context.issue_state_fetcher,
             delivered_revision
           ) do
        {:reconcile, refreshed_issue, refreshed_revision}
        when turn_number < turn_context.max_turns ->
          Logger.info("Forcing requirements reconciliation for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{turn_context.max_turns}")

          do_run_codex_turns(
            turn_context,
            refreshed_issue,
            turn_number + 1,
            refreshed_revision,
            RequirementsContext.steer_prompt(refreshed_issue, RequirementsContext.context(issue))
          )

        {:reconcile, refreshed_issue, refreshed_revision} ->
          {:error, {:requirements_stale_at_max_turns, refreshed_issue.id, delivered_revision, refreshed_revision}}

        {:continue, refreshed_issue} when turn_number < turn_context.max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{turn_context.max_turns}")

          do_run_codex_turns(
            turn_context,
            refreshed_issue,
            turn_number + 1,
            delivered_revision,
            nil
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(
         %Issue{id: issue_id} = issue,
         issue_state_fetcher,
         requirements_revision
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        refreshed_revision = RequirementsContext.revision(refreshed_issue)

        cond do
          cancellation_issue_state?(refreshed_issue.state) ->
            {:done, refreshed_issue}

          refreshed_revision != requirements_revision ->
            {:reconcile, refreshed_issue, refreshed_revision}

          active_issue_state?(refreshed_issue.state) ->
            {:continue, refreshed_issue}

          true ->
            {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _requirements_revision),
    do: {:done, issue}

  @doc false
  @spec completion_decision_for_test(Issue.t(), ([String.t()] -> term()), String.t()) ::
          {:continue, Issue.t()}
          | {:reconcile, Issue.t(), String.t()}
          | {:done, Issue.t()}
          | {:error, term()}
  def completion_decision_for_test(%Issue{} = issue, issue_state_fetcher, requirements_revision)
      when is_function(issue_state_fetcher, 1) and is_binary(requirements_revision) do
    continue_with_issue?(issue, issue_state_fetcher, requirements_revision)
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    Config.active_execution_state?(state_name)
  end

  defp active_issue_state?(_state_name), do: false

  defp cancellation_issue_state?(state_name) when is_binary(state_name) do
    normalized_state(state_name) in ["cancelled", "canceled", "duplicate", "archived"]
  end

  defp cancellation_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  # RFC 4122 v4 UUID; `claude --session-id` requires a valid UUID.
  defp uuid4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = <<u0::48, 4::4, u1::12, 2::2, u2::62>>

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end

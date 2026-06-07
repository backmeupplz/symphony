defmodule SymphonyElixir.Claude.PrintRunner do
  @moduledoc """
  Runs Claude Code in non-interactive print mode for one Symphony turn.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @max_output_bytes 200_000

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host) do
      session_id = "claude-#{System.unique_integer([:positive, :monotonic])}"
      metadata = %{claude_cli: true}

      emit_message(on_message, :session_started, %{session_id: session_id}, metadata)
      Logger.info("Claude print session started for #{issue_context(issue)} session_id=#{session_id}")

      result =
        case worker_host do
          host when is_binary(host) -> run_remote(host, expanded_workspace, prompt)
          _ -> run_local(expanded_workspace, prompt)
        end

      case result do
        {:ok, output} ->
          emit_message(on_message, :turn_completed, %{session_id: session_id, output: output}, metadata)
          Logger.info("Claude print session completed for #{issue_context(issue)} session_id=#{session_id}")
          {:ok, %{result: output, session_id: session_id, thread_id: session_id, turn_id: session_id}}

        {:error, reason} ->
          emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
          Logger.warning("Claude print session failed for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp run_local(workspace, prompt) do
    settings = Config.settings!().claude

    with {:ok, executable} <- resolve_executable(settings.command) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(local_args(settings, prompt), &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            env: env_vars(settings.env_file)
          ]
        )

      await_exit(port, settings.turn_timeout_ms, "")
    end
  end

  defp run_remote(worker_host, workspace, prompt) do
    settings = Config.settings!().claude

    command =
      [
        "cd #{shell_escape(workspace)}",
        source_env_command(settings.env_file),
        Enum.map_join(remote_args(settings, prompt), " ", &shell_escape/1)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" && ")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:claude_exit, status, truncate(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_args(settings, prompt) do
    # NOTE: do not pass --bare. It skips the credential-resolution path that
    # reads CLAUDE_CODE_OAUTH_TOKEN, so subscription auth fails with
    # "Not logged in". Plain --print resolves the token correctly.
    [
      "--print",
      "--model",
      settings.model,
      "--effort",
      settings.effort,
      "--permission-mode",
      settings.permission_mode,
      prompt
    ]
  end

  defp remote_args(settings, prompt), do: [settings.command | local_args(settings, prompt)]

  defp source_env_command(nil), do: nil
  defp source_env_command(""), do: nil
  defp source_env_command(path), do: ". #{shell_escape(path)}"

  defp resolve_executable(command) when is_binary(command) do
    cond do
      String.contains?(command, "/") and executable_file?(command) ->
        {:ok, command}

      String.contains?(command, "/") ->
        {:error, {:claude_command_not_executable, command}}

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, {:claude_command_not_found, command}}
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp env_vars(nil), do: []
  defp env_vars(""), do: []

  defp env_vars(path) do
    path
    |> Path.expand()
    |> File.read()
    |> case do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.flat_map(&parse_env_line/1)

      {:error, _reason} ->
        []
    end
  end

  defp parse_env_line(line) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        []

      true ->
        line = String.replace_prefix(line, "export ", "")

        case String.split(line, "=", parts: 2) do
          [key, value] when key != "" ->
            [{String.to_charlist(key), String.to_charlist(unquote_env_value(value))}]

          _ ->
            []
        end
    end
  end

  defp unquote_env_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      true ->
        value
    end
  end

  defp await_exit(port, timeout_ms, output) do
    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        await_exit(port, timeout_ms, append_output(output, chunk))

      {^port, {:data, {:eol, chunk}}} ->
        await_exit(port, timeout_ms, append_output(output, chunk <> "\n"))

      {^port, {:data, {:noeol, chunk}}} ->
        await_exit(port, timeout_ms, append_output(output, chunk))

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, status}} ->
        {:error, {:claude_exit, status, truncate(output)}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :turn_timeout}
    end
  end

  defp append_output(output, chunk) do
    next = output <> to_string(chunk)

    if byte_size(next) > @max_output_bytes do
      binary_part(next, byte_size(next) - @max_output_bytes, @max_output_bytes)
    else
      next
    end
  end

  defp truncate(text) when is_binary(text) and byte_size(text) > 2_000, do: binary_part(text, 0, 2_000)
  defp truncate(text), do: text

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp emit_message(on_message, event, payload, metadata) do
    on_message.(%{event: event, payload: payload, metadata: metadata})
  end

  defp default_on_message(_message), do: :ok

  defp issue_context(%{identifier: identifier, title: title}) do
    "#{identifier} #{inspect(title)}"
  end

  defp issue_context(issue), do: inspect(issue)
end

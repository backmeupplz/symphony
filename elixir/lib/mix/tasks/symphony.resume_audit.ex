defmodule Mix.Tasks.Symphony.ResumeAudit do
  use Mix.Task

  alias SymphonyElixir.ResumeAudit

  @shortdoc "Shows task-backed work that Symphony will recover after restart"

  @moduledoc """
  Prints a read-only restart/resume audit.

  The audit uses the configured tracker active states as the durable source of
  truth and checks preserved local workspace paths for each active task.
  """

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    case ResumeAudit.entries() do
      {:ok, entries} ->
        entries
        |> ResumeAudit.format_report()
        |> Mix.shell().info()

      {:error, reason} ->
        Mix.raise("Unable to build restart/resume audit: #{inspect(reason)}")
    end
  end
end

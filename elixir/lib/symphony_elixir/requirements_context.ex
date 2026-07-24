defmodule SymphonyElixir.RequirementsContext do
  @moduledoc """
  Builds the canonical, worker-facing requirements context for an issue.

  Revisions intentionally include only operator-controlled task requirements:
  title and description. Runtime state, assignment, timestamps, labels, and
  generated tracker activity such as the Codex workpad are excluded so worker
  progress cannot create a self-steering loop.
  """

  @type context :: %{title: String.t(), description: String.t()}

  @spec context(map()) :: context()
  def context(issue) when is_map(issue) do
    %{
      title: issue |> field(:title) |> normalize_text(),
      description: issue |> field(:description) |> normalize_text()
    }
  end

  @spec revision(map()) :: String.t()
  def revision(issue) when is_map(issue) do
    %{title: title, description: description} = context(issue)

    :crypto.hash(:sha256, [
      Integer.to_string(byte_size(title)),
      ":",
      title,
      Integer.to_string(byte_size(description)),
      ":",
      description
    ])
    |> Base.encode16(case: :lower)
  end

  @spec steer_prompt(map(), context() | map() | nil) :: String.t()
  def steer_prompt(issue, previous_context) when is_map(issue) do
    current = context(issue)
    previous = normalize_context(previous_context)
    identifier = issue |> field(:identifier) |> normalize_text()

    """
    Requirements changed while this turn is active for #{identifier_or_task(identifier)}.

    Mandatory: reconcile these requirements before further edits, validation, or completion. Treat the canonical context below as authoritative, update the workpad/acceptance checklist, and revisit any work already completed against the older requirements.

    Changed fields:
    #{changed_fields(previous, current)}

    Canonical requirements context:
    Title: #{present(current.title)}

    Description:
    #{present(current.description)}
    """
    |> String.trim()
  end

  defp normalize_context(%{title: title, description: description}) do
    %{title: normalize_text(title), description: normalize_text(description)}
  end

  defp normalize_context(%{"title" => title, "description" => description}) do
    %{title: normalize_text(title), description: normalize_text(description)}
  end

  defp normalize_context(_context), do: %{title: "", description: ""}

  defp changed_fields(previous, current) do
    []
    |> maybe_add_change("Title", previous.title, current.title)
    |> maybe_add_change("Description", previous.description, current.description)
    |> case do
      [] -> "- Canonical context was refreshed."
      changes -> Enum.join(changes, "\n")
    end
  end

  defp maybe_add_change(changes, _label, value, value), do: changes

  defp maybe_add_change(changes, label, previous, current) do
    changes ++
      [
        "- #{label} changed from #{inspect(summary(previous))} to #{inspect(summary(current))}."
      ]
  end

  defp summary(value) when byte_size(value) <= 160, do: value
  defp summary(value), do: String.slice(value, 0, 157) <> "..."

  defp present(""), do: "(empty)"
  defp present(value), do: value

  defp identifier_or_task(""), do: "the current task"
  defp identifier_or_task(identifier), do: identifier

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_text(nil), do: ""

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim()
  end

  defp normalize_text(value), do: to_string(value)
end

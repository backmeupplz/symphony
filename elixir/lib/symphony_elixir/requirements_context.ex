defmodule SymphonyElixir.RequirementsContext do
  @moduledoc """
  Builds the canonical, worker-facing requirements context for an issue.

  Revisions intentionally include only operator-controlled task requirements:
  title, description, and Kaneo comment activity explicitly headed
  `## Requirements Update`. Runtime state, assignment, timestamps, labels, and
  generated tracker activity such as the Codex workpad are excluded so worker
  progress cannot create a self-steering loop.
  """

  @requirement_update_heading "## Requirements Update"

  @type context :: %{
          title: String.t(),
          description: String.t(),
          requirement_updates: [String.t()]
        }

  @spec context(map()) :: context()
  def context(issue) when is_map(issue) do
    %{
      title: issue |> field(:title) |> normalize_text(),
      description: issue |> field(:description) |> normalize_text(),
      requirement_updates: issue |> field(:requirement_updates) |> normalize_updates()
    }
  end

  @spec revision(map()) :: String.t()
  def revision(issue) when is_map(issue) do
    %{title: title, description: description, requirement_updates: updates} = context(issue)

    :crypto.hash(:sha256, [
      encode_text(title),
      encode_text(description),
      Integer.to_string(length(updates)),
      ":",
      Enum.map(updates, &encode_text/1)
    ])
    |> Base.encode16(case: :lower)
  end

  @doc """
  Extracts canonical operator requirement updates from Kaneo activity.

  Only comment activity whose normalized first line exactly matches
  `## Requirements Update` is included. Results are ordered by creation time
  and activity id so Kaneo's reverse-chronological response order cannot change
  the revision.
  """
  @spec operator_requirement_updates(term()) :: [String.t()]
  def operator_requirement_updates(%{"data" => activities}),
    do: operator_requirement_updates(activities)

  def operator_requirement_updates(%{data: activities}),
    do: operator_requirement_updates(activities)

  def operator_requirement_updates(activities) when is_list(activities) do
    activities
    |> Enum.filter(&requirement_update_activity?/1)
    |> Enum.sort_by(&activity_sort_key/1)
    |> Enum.map(&(&1 |> field(:content) |> normalize_text()))
  end

  def operator_requirement_updates(_activities), do: []

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

    Operator requirement updates:
    #{present_updates(current.requirement_updates)}
    """
    |> String.trim()
  end

  defp normalize_context(context) when is_map(context) do
    %{
      title: context |> field(:title) |> normalize_text(),
      description: context |> field(:description) |> normalize_text(),
      requirement_updates: context |> field(:requirement_updates) |> normalize_updates()
    }
  end

  defp normalize_context(_context),
    do: %{title: "", description: "", requirement_updates: []}

  defp changed_fields(previous, current) do
    []
    |> maybe_add_change("Title", previous.title, current.title)
    |> maybe_add_change("Description", previous.description, current.description)
    |> maybe_add_change(
      "Operator requirements",
      format_updates(previous.requirement_updates),
      format_updates(current.requirement_updates)
    )
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

  defp present_updates([]), do: "(none)"
  defp present_updates(updates), do: Enum.join(updates, "\n\n")

  defp format_updates([]), do: ""
  defp format_updates(updates), do: Enum.join(updates, "\n\n")

  defp identifier_or_task(""), do: "the current task"
  defp identifier_or_task(identifier), do: identifier

  defp requirement_update_activity?(activity) when is_map(activity) do
    field(activity, :type) == "comment" and
      activity
      |> field(:content)
      |> normalize_text()
      |> requirement_update_content?()
  end

  defp requirement_update_activity?(_activity), do: false

  defp requirement_update_content?(content) do
    case String.split(content, "\n", parts: 2) do
      [@requirement_update_heading | _rest] -> true
      _other -> false
    end
  end

  defp activity_sort_key(activity) do
    {
      activity |> field(:created_at) |> fallback(field(activity, :createdAt)) |> normalize_text(),
      activity |> field(:id) |> normalize_text()
    }
  end

  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_updates(nil), do: []

  defp normalize_updates(updates) when is_list(updates) do
    updates
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_updates(update), do: [normalize_text(update)]

  defp encode_text(value) do
    [Integer.to_string(byte_size(value)), ":", value]
  end

  defp normalize_text(nil), do: ""

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim()
  end

  defp normalize_text(value), do: to_string(value)
end

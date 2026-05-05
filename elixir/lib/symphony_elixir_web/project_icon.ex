defmodule SymphonyElixirWeb.ProjectIcon do
  @moduledoc """
  Resolves project identity metadata into dashboard-safe icon payloads.
  """

  @palette [
    %{background: "#e8faf4", color: "#0f513f"},
    %{background: "#edf4ff", color: "#174ea6"},
    %{background: "#fff4de", color: "#8a5a00"},
    %{background: "#fceef6", color: "#9a1b61"},
    %{background: "#eef8e8", color: "#2f6b1f"},
    %{background: "#f4efff", color: "#5b31a6"},
    %{background: "#e9f7fb", color: "#0f6674"},
    %{background: "#f6f0e8", color: "#6b4b1f"}
  ]

  @curated_icons %{
    "sym" => :bot,
    "symphony" => :bot,
    "voi" => :audio,
    "voicy" => :audio,
    "egg" => :egg,
    "eggs" => :egg,
    "mkt" => :megaphone,
    "marketing" => :megaphone,
    "myg" => :map,
    "myground" => :map,
    "my-ground" => :map
  }

  @icon_aliases %{
    "audio" => :audio,
    "audiolines" => :audio,
    "audio-lines" => :audio,
    "mic" => :audio,
    "microphone" => :audio,
    "voice" => :audio,
    "volume2" => :audio,
    "volume-2" => :audio,
    "bot" => :bot,
    "robot" => :bot,
    "conductor" => :bot,
    "orchestration" => :bot,
    "egg" => :egg,
    "eggs" => :egg,
    "chicken" => :egg,
    "map" => :map,
    "mappin" => :map,
    "map-pin" => :map,
    "map-pinned" => :map,
    "mountain" => :map,
    "terrain" => :map,
    "location" => :map,
    "megaphone" => :megaphone,
    "campaign" => :megaphone,
    "chart" => :megaphone,
    "chart-no-axes-column-increasing" => :megaphone
  }

  @icon_labels %{
    audio: "Voice project",
    bot: "Symphony project",
    egg: "Eggs project",
    map: "Location project",
    megaphone: "Marketing project"
  }

  @paths %{
    audio: [
      "M9 18V6a3 3 0 0 1 6 0v12",
      "M6 10v4a6 6 0 0 0 12 0v-4",
      "M12 20v2",
      "M8 22h8"
    ],
    bot: [
      "M12 4v3",
      "M8 4h8",
      "M6 9h12a2 2 0 0 1 2 2v7a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3v-7a2 2 0 0 1 2-2Z",
      "M9 14h.01",
      "M15 14h.01",
      "M9 18h6"
    ],
    egg: [
      "M12 22c4 0 7-3.2 7-7.7C19 9.1 15.8 2 12 2S5 9.1 5 14.3C5 18.8 8 22 12 22Z",
      "M8.5 18.5l7-9"
    ],
    map: [
      "M9 18 3 21V6l6-3 6 3 6-3v15l-6 3-6-3Z",
      "M9 3v15",
      "M15 6v15"
    ],
    megaphone: [
      "M4 13h3l10 5V6L7 11H4v2Z",
      "M7 13l2 6h3",
      "M19 9v6"
    ]
  }

  @spec resolve(map()) :: map()
  def resolve(metadata) when is_map(metadata) do
    metadata = normalize_metadata(metadata)
    seed = icon_seed(metadata)

    case explicit_or_curated_icon(metadata) do
      nil ->
        fallback_icon(metadata, seed)

      icon ->
        icon_payload(icon, seed)
    end
  end

  @spec paths(atom() | String.t()) :: [String.t()]
  def paths(icon) when is_atom(icon), do: Map.get(@paths, icon, [])

  def paths(icon) when is_binary(icon) do
    icon
    |> String.to_existing_atom()
    |> paths()
  rescue
    ArgumentError -> []
  end

  @doc false
  @spec known_icon_for_test(term()) :: atom() | nil
  def known_icon_for_test(value), do: known_icon(value)

  defp normalize_metadata(metadata) do
    %{
      explicit_icon: first_present(metadata, [:project_icon, "project_icon", :icon, "icon"]),
      project_key: first_present(metadata, [:project_key, "project_key"]),
      project_slug: first_present(metadata, [:project_slug, "project_slug"]),
      project_name: first_present(metadata, [:project_name, "project_name"]),
      project_id: first_present(metadata, [:project_id, "project_id"]),
      issue_identifier: first_present(metadata, [:issue_identifier, "issue_identifier", :identifier, "identifier"])
    }
  end

  defp first_present(metadata, keys) do
    Enum.find_value(keys, fn key ->
      metadata
      |> Map.get(key)
      |> blank_to_nil()
    end)
  end

  defp explicit_or_curated_icon(metadata) do
    known_icon(metadata.explicit_icon) ||
      [metadata.project_slug, metadata.project_key, metadata.project_name]
      |> Enum.find_value(fn value ->
        value
        |> normalized_token()
        |> then(&Map.get(@curated_icons, &1))
      end)
  end

  defp known_icon(value) do
    value
    |> normalized_token()
    |> then(&Map.get(@icon_aliases, &1))
  end

  defp icon_payload(icon, seed) do
    colors = color_pair(seed)

    %{
      type: "svg",
      icon: Atom.to_string(icon),
      label: Map.fetch!(@icon_labels, icon),
      background: colors.background,
      color: colors.color,
      initials: nil
    }
  end

  defp fallback_icon(metadata, seed) do
    colors = color_pair(seed)

    %{
      type: "initials",
      icon: nil,
      label: "Project #{fallback_name(metadata)}",
      background: colors.background,
      color: colors.color,
      initials: initials(fallback_name(metadata))
    }
  end

  defp color_pair(seed) do
    Enum.at(@palette, :erlang.phash2(seed, length(@palette)))
  end

  defp icon_seed(metadata) do
    fallback_name(metadata)
    |> String.downcase()
  end

  defp fallback_name(metadata) do
    metadata.project_name ||
      metadata.project_key ||
      metadata.project_slug ||
      metadata.issue_identifier ||
      metadata.project_id ||
      "Project"
  end

  defp initials(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9]+/, " ")
    |> String.split(" ", trim: true)
    |> case do
      [] ->
        "PR"

      [single] ->
        single
        |> String.slice(0, 2)
        |> String.upcase()

      words ->
        words
        |> Enum.take(2)
        |> Enum.map_join(&String.first/1)
        |> String.upcase()
    end
  end

  defp normalized_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> blank_to_nil()
  end

  defp normalized_token(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_value), do: nil
end

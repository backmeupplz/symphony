defmodule SymphonyElixir.ActivityStream do
  @moduledoc """
  In-memory realtime activity stream for trusted bot/project updates.

  Events are intentionally short, caller-supplied display strings. Emitters are
  responsible for anonymizing user, chat, and message details before submission.
  """

  use GenServer

  @topic "activity_stream:events"
  @default_max_events 200
  @default_max_text_bytes 500
  @default_rate_limit_window_ms 1_000
  @default_rate_limit_max_events 20

  @type event :: %{
          id: String.t(),
          timestamp: String.t(),
          text: String.t(),
          source: String.t() | nil,
          project: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec submit(map(), keyword()) :: {:ok, event()} | {:error, atom()}
  def submit(attrs, opts \\ []) when is_map(attrs) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:submit, attrs, opts})
  end

  @spec recent(keyword()) :: [event()]
  def recent(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    limit = Keyword.get(opts, :limit, max_events())
    GenServer.call(server, {:recent, limit})
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    if Process.whereis(SymphonyElixir.PubSub) do
      Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, @topic)
    else
      {:error, :pubsub_unavailable}
    end
  end

  @spec broadcast_topic() :: String.t()
  def broadcast_topic, do: @topic

  @spec max_events() :: pos_integer()
  def max_events, do: positive_env("SYMPHONY_ACTIVITY_MAX_EVENTS", @default_max_events)

  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: positive_env("SYMPHONY_ACTIVITY_MAX_TEXT_BYTES", @default_max_text_bytes)

  @spec rate_limit_window_ms() :: pos_integer()
  def rate_limit_window_ms do
    positive_env("SYMPHONY_ACTIVITY_RATE_LIMIT_WINDOW_MS", @default_rate_limit_window_ms)
  end

  @spec rate_limit_max_events() :: pos_integer()
  def rate_limit_max_events do
    positive_env("SYMPHONY_ACTIVITY_RATE_LIMIT_MAX_EVENTS", @default_rate_limit_max_events)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       events: [],
       max_events: Keyword.get(opts, :max_events, max_events()),
       max_text_bytes: Keyword.get(opts, :max_text_bytes, max_text_bytes()),
       rate_limit_window_ms: Keyword.get(opts, :rate_limit_window_ms, rate_limit_window_ms()),
       rate_limit_max_events: Keyword.get(opts, :rate_limit_max_events, rate_limit_max_events()),
       rate_limits: %{}
     }}
  end

  @impl true
  def handle_call({:submit, attrs, opts}, _from, state) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    rate_key = Keyword.get(opts, :rate_key, :default)

    with {:ok, rate_limits} <- check_rate_limit(state, rate_key, now_ms),
         {:ok, event} <- build_event(attrs, state.max_text_bytes) do
      events = [event | state.events] |> Enum.take(state.max_events)
      broadcast(event)
      {:reply, {:ok, event}, %{state | events: events, rate_limits: rate_limits}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recent, limit}, _from, state) do
    safe_limit =
      limit
      |> normalize_positive_integer(state.max_events)
      |> min(state.max_events)

    {:reply, state.events |> Enum.take(safe_limit) |> Enum.reverse(), state}
  end

  defp build_event(attrs, max_text_bytes) do
    text =
      attrs
      |> Map.get("text", Map.get(attrs, :text, Map.get(attrs, "event", Map.get(attrs, :event))))
      |> normalize_text()

    cond do
      text == "" ->
        {:error, :missing_text}

      byte_size(text) > max_text_bytes ->
        {:error, :payload_too_large}

      true ->
        {:ok,
         %{
           id: unique_id(),
           timestamp: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
           text: text,
           source: metadata_value(attrs, "source"),
           project: metadata_value(attrs, "project")
         }}
    end
  end

  defp metadata_value(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, String.to_atom(key)))
    |> normalize_optional()
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
  end

  defp normalize_text(_value), do: ""

  defp normalize_optional(value) when is_binary(value) do
    value
    |> normalize_text()
    |> case do
      "" -> nil
      cleaned -> String.slice(cleaned, 0, 64)
    end
  end

  defp normalize_optional(_value), do: nil

  defp check_rate_limit(state, rate_key, now_ms) do
    window_started_at = now_ms - state.rate_limit_window_ms

    recent_hits =
      state.rate_limits
      |> Map.get(rate_key, [])
      |> Enum.filter(&(&1 >= window_started_at))

    if length(recent_hits) >= state.rate_limit_max_events do
      {:error, :rate_limited}
    else
      rate_limits =
        state.rate_limits
        |> Map.put(rate_key, [now_ms | recent_hits])
        |> prune_rate_limits(window_started_at)

      {:ok, rate_limits}
    end
  end

  defp prune_rate_limits(rate_limits, window_started_at) do
    Map.new(rate_limits, fn {key, hits} ->
      {key, Enum.filter(hits, &(&1 >= window_started_at))}
    end)
  end

  defp broadcast(event) do
    if Process.whereis(SymphonyElixir.PubSub) do
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, @topic, {:activity_stream_event, event})
    end

    :ok
  end

  defp unique_id do
    "evt_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp positive_env(name, default) do
    name
    |> System.get_env()
    |> normalize_positive_integer(default)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default
end

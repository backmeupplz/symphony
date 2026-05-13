defmodule SymphonyElixir.ActivityStreamTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ActivityStream
  alias SymphonyElixirWeb.ActivityStreamSocket

  test "stores bounded sanitized events and returns recent replay oldest first" do
    name = start_supervised!({ActivityStream, name: unique_name(), max_events: 2})

    assert {:ok, first} =
             ActivityStream.submit(%{"text" => "  Chat 1***34 sent a message  ", "source" => "bot"}, server: name)

    assert {:ok, _second} = ActivityStream.submit(%{"text" => "Project action"}, server: name)

    assert {:ok, third} =
             ActivityStream.submit(%{"text" => "Done\x00 now", "project" => "voicy", "source" => "\x00"}, server: name)

    assert first.text == "Chat 1***34 sent a message"
    assert third.text == "Done now"
    assert third.source == nil

    replay = ActivityStream.recent(server: name)

    assert Enum.map(replay, & &1.text) == ["Project action", "Done now"]
    assert Enum.all?(replay, &String.starts_with?(&1.id, "evt_"))
    assert Enum.all?(replay, &match?({:ok, _, _}, DateTime.from_iso8601(&1.timestamp)))
  end

  test "exposes stream configuration helpers from environment" do
    previous_max_events = System.get_env("SYMPHONY_ACTIVITY_MAX_EVENTS")
    previous_max_text = System.get_env("SYMPHONY_ACTIVITY_MAX_TEXT_BYTES")

    on_exit(fn ->
      restore_env("SYMPHONY_ACTIVITY_MAX_EVENTS", previous_max_events)
      restore_env("SYMPHONY_ACTIVITY_MAX_TEXT_BYTES", previous_max_text)
    end)

    System.put_env("SYMPHONY_ACTIVITY_MAX_EVENTS", "123")
    System.put_env("SYMPHONY_ACTIVITY_MAX_TEXT_BYTES", "bad")

    assert ActivityStream.broadcast_topic() == "activity_stream:events"
    assert ActivityStream.max_events() == 123
    assert ActivityStream.max_text_bytes() == 500
  end

  test "rejects missing text, oversized text, and excessive submissions" do
    opts = [
      name: unique_name(),
      max_text_bytes: 5,
      rate_limit_window_ms: 1_000,
      rate_limit_max_events: 2
    ]

    name = start_supervised!({ActivityStream, opts})

    assert {:error, :missing_text} = ActivityStream.submit(%{}, server: name)
    assert {:error, :payload_too_large} = ActivityStream.submit(%{"text" => "123456"}, server: name)

    assert {:ok, _event} = ActivityStream.submit(%{"text" => "one"}, server: name, rate_key: :client, now_ms: 1)
    assert {:ok, _event} = ActivityStream.submit(%{"text" => "two"}, server: name, rate_key: :client, now_ms: 2)
    assert {:error, :rate_limited} = ActivityStream.submit(%{"text" => "tri"}, server: name, rate_key: :client, now_ms: 3)

    assert {:ok, _event} = ActivityStream.submit(%{"text" => "tri"}, server: name, rate_key: :client, now_ms: 1_100)
  end

  test "websocket handler replays recent events and pushes live broadcasts" do
    assert {:ok, _event} = ActivityStream.submit(%{"text" => "replay from default stream"})

    assert {:push, replay_frames, %{}} = ActivityStreamSocket.init(replay_limit: 1)
    assert [{:text, replay_json}] = replay_frames
    assert %{"type" => "event", "event" => %{"text" => "replay from default stream"}} = Jason.decode!(replay_json)

    event = %{id: "evt_test", timestamp: DateTime.utc_now() |> DateTime.to_iso8601(), text: "live", source: nil, project: nil}

    assert {:push, {:text, live_json}, %{}} = ActivityStreamSocket.handle_info({:activity_stream_event, event}, %{})
    assert %{"type" => "event", "event" => %{"id" => "evt_test", "text" => "live"}} = Jason.decode!(live_json)
  end

  defp unique_name do
    :"activity_stream_#{System.unique_integer([:positive])}"
  end
end

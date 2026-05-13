defmodule SymphonyElixirWeb.ActivityStreamSocket do
  @moduledoc """
  Plain WebSocket stream for recent and live project activity events.
  """

  @behaviour WebSock

  alias SymphonyElixir.ActivityStream

  @impl true
  def init(opts) do
    :ok = ActivityStream.subscribe()

    limit = Keyword.get(opts, :replay_limit, ActivityStream.max_events())

    frames =
      [limit: limit]
      |> ActivityStream.recent()
      |> Enum.map(&event_frame/1)

    {:push, frames, %{}}
  end

  @impl true
  def handle_in({"ping", [opcode: :text]}, state) do
    {:push, {:text, ~s({"type":"pong"})}, state}
  end

  def handle_in({_payload, [opcode: :text]}, state), do: {:ok, state}
  def handle_in({_payload, [opcode: :binary]}, state), do: {:ok, state}

  @impl true
  def handle_info({:activity_stream_event, event}, state) do
    {:push, event_frame(event), state}
  end

  def handle_info(_message, state), do: {:ok, state}

  defp event_frame(event) do
    {:text, Jason.encode!(%{type: "event", event: event})}
  end
end

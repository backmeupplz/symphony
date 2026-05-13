defmodule SymphonyElixirWeb.ActivityStreamController do
  @moduledoc """
  HTTP and WebSocket entrypoints for the project activity stream.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.ActivityStream
  alias SymphonyElixirWeb.ActivityStreamSocket

  @token_env "SYMPHONY_ACTIVITY_TOKEN"
  @cors_origin_env "SYMPHONY_ACTIVITY_CORS_ORIGIN"

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      recent_count: length(ActivityStream.recent()),
      max_events: ActivityStream.max_events(),
      max_text_bytes: ActivityStream.max_text_bytes()
    })
  end

  @spec submit(Conn.t(), map()) :: Conn.t()
  def submit(conn, params) do
    conn = put_cors_headers(conn)

    with :ok <- require_configured_token(),
         :ok <- authenticate(conn),
         {:ok, event} <- ActivityStream.submit(params, rate_key: rate_key(conn)) do
      conn
      |> put_status(202)
      |> json(%{event: event})
    else
      {:error, :missing_secret} ->
        error_response(conn, 503, "activity_secret_missing", "Activity submit token is not configured")

      {:error, :unauthorized} ->
        error_response(conn, 401, "unauthorized", "Missing or invalid activity token")

      {:error, :missing_text} ->
        error_response(conn, 422, "missing_text", "Request body must include a non-empty text field")

      {:error, :payload_too_large} ->
        error_response(conn, 413, "payload_too_large", "Activity text exceeds the configured byte limit")

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", retry_after_seconds())
        |> error_response(429, "rate_limited", "Activity submit rate limit exceeded")
    end
  end

  @spec options(Conn.t(), map()) :: Conn.t()
  def options(conn, _params) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
  end

  @spec stream(Conn.t(), map()) :: Conn.t()
  def stream(conn, params) do
    if allowed_origin?(conn) do
      replay_limit =
        params
        |> Map.get("replay")
        |> parse_replay_limit()

      WebSockAdapter.upgrade(conn, ActivityStreamSocket, [replay_limit: replay_limit],
        timeout: 60_000,
        max_frame_size: 1024
      )
    else
      error_response(conn, 403, "origin_not_allowed", "WebSocket origin is not allowed")
    end
  end

  defp require_configured_token do
    case configured_token() do
      token when is_binary(token) and byte_size(token) > 0 -> :ok
      _ -> {:error, :missing_secret}
    end
  end

  defp authenticate(conn) do
    expected = configured_token()
    supplied = submitted_token(conn)

    cond do
      not is_binary(supplied) ->
        {:error, :unauthorized}

      secure_compare(supplied, expected) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp configured_token do
    @token_env
    |> System.get_env()
    |> case do
      nil -> nil
      token -> String.trim(token)
    end
  end

  defp submitted_token(conn) do
    bearer_token(conn) ||
      header_token(conn, "x-activity-token") ||
      header_token(conn, "x-symphony-activity-token")
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> String.trim(token)
      "bearer " <> token -> String.trim(token)
      _ -> nil
    end
  end

  defp header_token(conn, name) do
    conn
    |> get_req_header(name)
    |> List.first()
    |> case do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp rate_key(%Conn{remote_ip: remote_ip}), do: {:ip, remote_ip}

  defp retry_after_seconds do
    ActivityStream.rate_limit_window_ms()
    |> div(1_000)
    |> max(1)
    |> Integer.to_string()
  end

  defp parse_replay_limit(nil), do: ActivityStream.max_events()

  defp parse_replay_limit(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, ActivityStream.max_events())
      _ -> ActivityStream.max_events()
    end
  end

  defp put_cors_headers(conn) do
    origin = allowed_cors_origin(conn)

    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", "POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type, x-activity-token, x-symphony-activity-token")
  end

  defp allowed_cors_origin(conn) do
    configured_origin = System.get_env(@cors_origin_env, "*") |> String.trim()

    cond do
      configured_origin in ["", "*"] ->
        "*"

      origin_allowed?(conn, configured_origin) ->
        configured_origin

      true ->
        "null"
    end
  end

  defp allowed_origin?(conn) do
    configured_origin = System.get_env(@cors_origin_env, "*") |> String.trim()
    configured_origin in ["", "*"] or origin_allowed?(conn, configured_origin)
  end

  defp origin_allowed?(conn, configured_origin) do
    conn
    |> get_req_header("origin")
    |> List.first()
    |> case do
      nil -> true
      origin -> origin == configured_origin
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end

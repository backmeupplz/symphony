defmodule SymphonyElixir.ActivityStreamControllerTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  @endpoint SymphonyElixirWeb.Endpoint
  @token "12345678901234567890123456789012345"

  setup do
    previous_token = System.get_env("SYMPHONY_ACTIVITY_TOKEN")
    previous_origin = System.get_env("SYMPHONY_ACTIVITY_CORS_ORIGIN")
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    System.put_env("SYMPHONY_ACTIVITY_TOKEN", @token)
    System.delete_env("SYMPHONY_ACTIVITY_CORS_ORIGIN")
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.merge(endpoint_config, server: false))
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      restore_env("SYMPHONY_ACTIVITY_TOKEN", previous_token)
      restore_env("SYMPHONY_ACTIVITY_CORS_ORIGIN", previous_origin)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "health returns service limits" do
    response =
      conn(:get, "/activity/v1/health")
      |> @endpoint.call([])

    assert response.status == 200
    assert response.resp_body =~ ~s("status":"ok")
  end

  test "submit requires configured bearer token and accepts short activity text" do
    missing_token =
      conn(:post, "/activity/v1/events", %{text: "Chat 1***34 sent a message"})
      |> @endpoint.call([])

    assert missing_token.status == 401

    wrong_token =
      conn(:post, "/activity/v1/events", %{text: "Chat 1***34 sent a message"})
      |> put_req_header("authorization", "Bearer wrong")
      |> @endpoint.call([])

    assert wrong_token.status == 401

    accepted =
      conn(:post, "/activity/v1/events", %{text: "Chat 1***34 sent a message", project: "voicy", source: "bot"})
      |> put_req_header("authorization", "Bearer #{@token}")
      |> @endpoint.call([])

    assert accepted.status == 202

    assert %{
             "event" => %{
               "text" => "Chat 1***34 sent a message",
               "project" => "voicy",
               "source" => "bot"
             }
           } = Jason.decode!(accepted.resp_body)
  end

  test "submit handles preflight and missing secret without exposing token values" do
    preflight =
      conn(:options, "/activity/v1/events")
      |> @endpoint.call([])

    assert preflight.status == 204
    assert get_resp_header(preflight, "access-control-allow-origin") == ["*"]

    System.delete_env("SYMPHONY_ACTIVITY_TOKEN")

    response =
      conn(:post, "/activity/v1/events", %{text: "hidden"})
      |> put_req_header("authorization", "Bearer #{@token}")
      |> @endpoint.call([])

    assert response.status == 503
    refute response.resp_body =~ @token
  end

  test "stream rejects disallowed origins before websocket upgrade" do
    System.put_env("SYMPHONY_ACTIVITY_CORS_ORIGIN", "https://borodutch.com")

    response =
      conn(:get, "/activity/v1/stream")
      |> put_req_header("origin", "https://example.com")
      |> @endpoint.call([])

    assert response.status == 403
  end
end

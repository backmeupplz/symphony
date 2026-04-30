defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Kaneo
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @kaneo_api_tool "kaneo_api"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @kaneo_api_description """
  Execute an authenticated REST request against Kaneo using Symphony's configured auth.
  """
  @kaneo_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method, for example GET, POST, PUT, PATCH, or DELETE."
      },
      "path" => %{
        "type" => "string",
        "description" => "Kaneo API path, for example /task/{id} or /comment/{taskId}."
      },
      "body" => %{
        "type" => ["object", "array", "null"],
        "description" => "Optional JSON request body."
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @kaneo_api_tool ->
        execute_kaneo_api(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @kaneo_api_tool,
        "description" => @kaneo_api_description,
        "inputSchema" => @kaneo_api_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_kaneo_api(arguments, opts) do
    kaneo_client = Keyword.get(opts, :kaneo_client, &Kaneo.Client.request/3)

    with {:ok, method, path, req_opts} <- normalize_kaneo_api_arguments(arguments),
         {:ok, response} <- kaneo_client.(method, path, req_opts) do
      dynamic_tool_response(response.status in 200..299, encode_payload(response.body))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_kaneo_api_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_kaneo_method(arguments),
         {:ok, path} <- normalize_kaneo_path(arguments),
         {:ok, req_opts} <- normalize_kaneo_req_opts(arguments) do
      {:ok, method, path, req_opts}
    end
  end

  defp normalize_kaneo_api_arguments(_arguments), do: {:error, :invalid_kaneo_arguments}

  defp normalize_kaneo_method(arguments) do
    case Map.get(arguments, "method") || Map.get(arguments, :method) do
      method when is_binary(method) ->
        method =
          method
          |> String.trim()
          |> String.downcase()

        case method do
          "get" ->
            {:ok, :get}

          "post" ->
            {:ok, :post}

          "put" ->
            {:ok, :put}

          "patch" ->
            {:ok, :patch}

          "delete" ->
            {:ok, :delete}

          _ ->
            {:error, :invalid_kaneo_method}
        end

      _ ->
        {:error, :invalid_kaneo_method}
    end
  end

  defp normalize_kaneo_path(arguments) do
    case Map.get(arguments, "path") || Map.get(arguments, :path) do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> {:error, :missing_kaneo_path}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_kaneo_path}
    end
  end

  defp normalize_kaneo_req_opts(arguments) do
    with {:ok, body} <- normalize_optional_json_value(arguments, "body"),
         {:ok, params} <- normalize_optional_map_value(arguments, "params") do
      req_opts =
        []
        |> maybe_put_req_opt(:json, body)
        |> maybe_put_req_opt(:params, params)

      {:ok, req_opts}
    end
  end

  defp normalize_optional_json_value(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      nil -> {:ok, nil}
      value when is_map(value) or is_list(value) -> {:ok, value}
      _ -> {:error, :invalid_kaneo_body}
    end
  end

  defp normalize_optional_map_value(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_kaneo_params}
    end
  end

  defp maybe_put_req_opt(opts, _key, nil), do: opts
  defp maybe_put_req_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:missing_kaneo_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Kaneo auth. Set `tracker.api_key` in `WORKFLOW.md` or export `KANEO_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:invalid_kaneo_arguments) do
    %{
      "error" => %{
        "message" => "`kaneo_api` expects an object with `method`, `path`, and optional `body`/`params`."
      }
    }
  end

  defp tool_error_payload(:invalid_kaneo_method) do
    %{
      "error" => %{
        "message" => "`kaneo_api.method` must be one of GET, POST, PUT, PATCH, or DELETE."
      }
    }
  end

  defp tool_error_payload(:missing_kaneo_path) do
    %{
      "error" => %{
        "message" => "`kaneo_api.path` must be a non-empty Kaneo API path."
      }
    }
  end

  defp tool_error_payload(:invalid_kaneo_body) do
    %{
      "error" => %{
        "message" => "`kaneo_api.body` must be a JSON object, array, or null."
      }
    }
  end

  defp tool_error_payload(:invalid_kaneo_params) do
    %{
      "error" => %{
        "message" => "`kaneo_api.params` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload({:kaneo_api_status, status}) do
    %{
      "error" => %{
        "message" => "Kaneo REST request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:kaneo_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Kaneo REST request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end

defmodule SymphonyElixir.Kaneo.Client do
  @moduledoc """
  Thin Kaneo REST client for polling project tasks.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @default_endpoint "https://cloud.kaneo.app/api"
  @linear_default_endpoint "https://api.linear.app/graphql"
  @max_error_body_log_bytes 1_000

  @priority_rank %{
    "urgent" => 1,
    "high" => 2,
    "medium" => 3,
    "low" => 4,
    "no-priority" => nil
  }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter(),
         {:ok, issues} <- do_fetch_by_states(tracker.project_id, tracker.active_states, assignee_filter) do
      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_tracker_config(tracker),
           {:ok, assignee_filter} <- routing_assignee_filter() do
        do_fetch_by_states(tracker.project_id, normalized_states, assignee_filter)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, assignee_filter} <- routing_assignee_filter() do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn
        _issue_id, {:error, reason} ->
          {:halt, {:error, reason}}

        issue_id, {:ok, issues} ->
          case get_task(issue_id, assignee_filter) do
            {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(task_id, body) when is_binary(task_id) and is_binary(body) do
    case request(:post, "/comment/#{URI.encode(task_id)}", json: %{content: body}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, response} -> {:error, {:kaneo_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec assign_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def assign_issue(task_id, assignee_id)
      when is_binary(task_id) and is_binary(assignee_id) do
    case request(:put, "/task/assignee/#{URI.encode(task_id)}", json: %{userId: assignee_id}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, response} -> {:error, {:kaneo_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(task_id, state_name) when is_binary(task_id) and is_binary(state_name) do
    case request(:put, "/task/status/#{URI.encode(task_id)}", json: %{status: state_name}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, response} -> {:error, {:kaneo_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request(atom(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def request(method, path, opts \\ []) when is_atom(method) and is_binary(path) and is_list(opts) do
    with {:ok, headers} <- rest_headers() do
      req_opts =
        opts
        |> Keyword.put(:headers, headers)
        |> Keyword.put(:connect_options, timeout: 30_000)

      path
      |> build_url()
      |> Req.request([method: method] ++ req_opts)
      |> case do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, response} ->
          Logger.error("Kaneo REST request failed status=#{response.status} body=#{summarize_error_body(response.body)}")
          {:ok, response}

        {:error, reason} ->
          Logger.error("Kaneo REST request failed: #{inspect(reason)}")
          {:error, {:kaneo_api_request, reason}}
      end
    end
  end

  @doc false
  @spec normalize_task_for_test(map()) :: Issue.t() | nil
  def normalize_task_for_test(task) when is_map(task), do: normalize_task(task)

  @doc false
  @spec flatten_tasks_response_for_test(term()) :: [map()]
  def flatten_tasks_response_for_test(response), do: flatten_tasks_response(response)

  defp do_fetch_by_states(project_id, state_names, assignee_filter) do
    state_names
    |> Enum.reduce_while({:ok, []}, fn
      _state_name, {:error, reason} ->
        {:halt, {:error, reason}}

      state_name, {:ok, issues} ->
        query = [status: state_name, sortBy: "priority", sortOrder: "asc"]

        case request(:get, "/task/tasks/#{URI.encode(project_id)}", params: query) do
          {:ok, %{body: body}} ->
            fetched_issues =
              body
              |> flatten_tasks_response()
              |> Enum.map(&normalize_task(&1, assignee_filter))
              |> Enum.reject(&is_nil/1)

            {:cont, {:ok, fetched_issues ++ issues}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, issues} -> {:ok, sort_and_dedupe_issues(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_task(task_id, assignee_filter) do
    with :ok <- validate_tracker_config(Config.settings!().tracker),
         {:ok, %{body: body}} <- request(:get, "/task/#{URI.encode(task_id)}") do
      case body |> unwrap_data() |> normalize_task(assignee_filter) do
        %Issue{} = issue -> {:ok, issue}
        nil -> {:error, :kaneo_unknown_payload}
      end
    end
  end

  defp validate_tracker_config(tracker) do
    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_kaneo_api_token}
      not is_binary(tracker.project_id) -> {:error, :missing_kaneo_project_id}
      true -> :ok
    end
  end

  defp rest_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_kaneo_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp build_url(path) do
    endpoint() <> "/" <> String.trim_leading(path, "/")
  end

  defp endpoint do
    Config.settings!().tracker.endpoint
    |> normalize_endpoint()
  end

  defp normalize_endpoint(nil), do: @default_endpoint
  defp normalize_endpoint(""), do: @default_endpoint
  defp normalize_endpoint(@linear_default_endpoint), do: @default_endpoint

  defp normalize_endpoint(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.trim()
    |> String.trim_trailing("/")
    |> then(fn
      "" -> @default_endpoint
      endpoint -> endpoint
    end)
  end

  defp flatten_tasks_response(%{"data" => data}), do: flatten_tasks_response(data)
  defp flatten_tasks_response(%{data: data}), do: flatten_tasks_response(data)

  defp flatten_tasks_response(%{"columns" => columns}) when is_list(columns) do
    Enum.flat_map(columns, fn
      %{"tasks" => tasks} when is_list(tasks) -> tasks
      _ -> []
    end)
  end

  defp flatten_tasks_response(%{columns: columns}) when is_list(columns) do
    Enum.flat_map(columns, fn
      %{tasks: tasks} when is_list(tasks) -> tasks
      %{"tasks" => tasks} when is_list(tasks) -> tasks
      _ -> []
    end)
  end

  defp flatten_tasks_response(tasks) when is_list(tasks), do: tasks
  defp flatten_tasks_response(%{"tasks" => tasks}) when is_list(tasks), do: tasks
  defp flatten_tasks_response(%{tasks: tasks}) when is_list(tasks), do: tasks
  defp flatten_tasks_response(_response), do: []

  defp unwrap_data(%{"data" => data}), do: data
  defp unwrap_data(%{data: data}), do: data
  defp unwrap_data(response), do: response

  defp normalize_task(task, assignee_filter \\ nil)

  defp normalize_task(task, assignee_filter) when is_map(task) do
    assignee_id =
      task_field(task, "userId") || get_in(task, ["assignee", "id"]) || get_in(task, [:assignee, :id])

    %Issue{
      id: task_field(task, "id"),
      identifier: task_identifier(task),
      title: task_field(task, "title"),
      description: task_field(task, "description"),
      priority: parse_priority(task_field(task, "priority")),
      state: task_field(task, "status"),
      branch_name: nil,
      url: nil,
      assignee_id: assignee_id,
      blocked_by: [],
      labels: [],
      assigned_to_worker: assigned_to_worker?(assignee_id, assignee_filter),
      created_at: parse_datetime(task_field(task, "createdAt")),
      updated_at: parse_datetime(task_field(task, "updatedAt"))
    }
  end

  defp normalize_task(_task, _assignee_filter), do: nil

  defp task_field(task, key) when is_map(task) and is_binary(key) do
    Map.get(task, key) || Map.get(task, String.to_atom(key))
  end

  defp task_identifier(task) do
    case task_field(task, "number") do
      number when is_integer(number) -> "KANEO-#{number}"
      number when is_binary(number) and number != "" -> "KANEO-#{number}"
      _ -> task_field(task, "id")
    end
  end

  defp parse_priority(priority) when is_binary(priority) do
    Map.get(@priority_rank, String.downcase(priority))
  end

  defp parse_priority(_priority), do: nil

  defp assigned_to_worker?(_assignee_id, nil), do: true
  defp assigned_to_worker?(nil, _assignee_filter), do: true

  defp assigned_to_worker?(assignee_id, %{match_values: match_values}) when is_map(match_values) do
    case normalize_assignee_match_value(assignee_id) do
      nil -> false
      normalized -> MapSet.member?(match_values, normalized)
    end
  end

  defp assigned_to_worker?(_assignee_id, _assignee_filter), do: false

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil -> {:ok, nil}
      normalized -> {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp sort_and_dedupe_issues(issues) do
    issues
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(fn issue ->
      {
        issue.priority || 99,
        issue.created_at || ~U[9999-12-31 23:59:59Z],
        issue.identifier || issue.id || ""
      }
    end)
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end

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
    settings = Config.settings!()
    tracker = settings.tracker
    projects = Config.kaneo_projects(settings)

    with :ok <- validate_tracker_config(tracker, projects) do
      fetch_projects_by_states(projects, &project_active_states/1)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    state_names
    |> normalize_state_names()
    |> fetch_normalized_states()
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    settings = Config.settings!()
    tracker = settings.tracker
    projects = Config.kaneo_projects(settings)

    with :ok <- validate_tracker_config(tracker, projects),
         {:ok, wanted_ids} <- normalize_issue_ids(issue_ids) do
      projects
      |> fetch_projects_by_states(&project_refresh_states/1)
      |> case do
        {:ok, issues} ->
          {:ok, Enum.filter(issues, &MapSet.member?(wanted_ids, &1.id))}

        {:error, reason} ->
          {:error, reason}
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

      ([method: method, url: build_url(path)] ++ req_opts)
      |> kaneo_request_fun().()
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
  @spec normalize_task_for_test(map(), map()) :: Issue.t() | nil
  def normalize_task_for_test(task, project) when is_map(task) and is_map(project),
    do: normalize_task(task, project)

  @doc false
  @spec flatten_tasks_response_for_test(term()) :: [map()]
  def flatten_tasks_response_for_test(response), do: flatten_tasks_response(response)

  defp fetch_projects_by_states(projects, states_fun) when is_list(projects) and is_function(states_fun, 1) do
    projects
    |> Enum.reduce_while({:ok, []}, fn
      project, {:ok, issues} ->
        case project |> states_fun.() |> do_fetch_by_states(project) do
          {:ok, project_issues} -> {:cont, {:ok, project_issues ++ issues}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, issues} -> {:ok, sort_and_dedupe_issues(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_fetch_by_states(state_names, %{id: project_id} = project) do
    state_names
    |> Enum.reduce_while({:ok, []}, fn
      state_name, {:ok, issues} ->
        query = [status: state_name, sortBy: "priority", sortOrder: "asc"]

        case request(:get, "/task/tasks/#{URI.encode(project_id)}", params: query) do
          {:ok, %{body: body}} ->
            fetched_issues =
              body
              |> flatten_tasks_response()
              |> Enum.map(&normalize_task(&1, project))
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

  defp validate_tracker_config(tracker, projects) do
    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_kaneo_api_token}
      projects == [] -> {:error, :missing_kaneo_project_id}
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

  defp kaneo_request_fun do
    Application.get_env(:symphony_elixir, :kaneo_request_fun, &Req.request/1)
  end

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

  defp normalize_issue_ids(issue_ids) do
    issue_ids =
      issue_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> MapSet.new()

    {:ok, issue_ids}
  end

  defp normalize_state_names(state_names) do
    state_names
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp fetch_normalized_states([]), do: {:ok, []}

  defp fetch_normalized_states(normalized_states) do
    settings = Config.settings!()
    tracker = settings.tracker
    projects = Config.kaneo_projects(settings)

    with :ok <- validate_tracker_config(tracker, projects) do
      fetch_projects_by_states(projects, fn _project -> normalized_states end)
    end
  end

  defp project_active_states(%{active_states: active_states}) when is_list(active_states), do: active_states

  defp project_refresh_states(%{active_states: active_states, terminal_states: terminal_states}) do
    (active_states ++ terminal_states)
    |> Enum.uniq()
  end

  defp normalize_task(task, project \\ nil)

  defp normalize_task(task, project) when is_map(task) do
    assignee_id =
      task_field(task, "userId") || get_in(task, ["assignee", "id"]) || get_in(task, [:assignee, :id])

    project = normalize_project_context(task, project)
    selected_repos = select_project_repos(task, project)
    primary_repo = List.first(selected_repos)
    tracker_identifier = task_identifier(task)

    %Issue{
      id: task_field(task, "id"),
      identifier: issue_identifier(tracker_identifier, project),
      title: task_field(task, "title"),
      description: task_field(task, "description"),
      priority: parse_priority(task_field(task, "priority")),
      state: task_field(task, "status"),
      branch_name: nil,
      url: nil,
      assignee_id: assignee_id,
      project_id: project.id,
      project_name: project.name,
      project_slug: project.slug,
      project_key: project.key,
      tracker_identifier: tracker_identifier,
      source_repo_key: repo_value(primary_repo, "key"),
      source_repo_url: repo_value(primary_repo, "repo_url"),
      source_repo_ref: repo_value(primary_repo, "repo_ref"),
      source_repos: selected_repos,
      workflow_file: repo_value(primary_repo, "workflow_file") || project.workflow_file,
      blocked_by: [],
      labels: [],
      assigned_to_worker: assigned_to_worker?(assignee_id, project.assignee_filter),
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

  defp normalize_project_context(task, project) do
    project_id = task_field(task, "projectId") || project_value(project, :id)
    project_name = project_value(project, :name)
    project_slug = project_value(project, :slug)
    project_key = project_key(project_slug, project_name, project_id, project_value(project, :legacy?))
    assignee = project_value(project, :assignee)

    %{
      id: project_id,
      name: project_name,
      slug: project_slug,
      key: project_key,
      repo_url: blank_to_nil(project_value(project, :repo_url)),
      repo_ref: blank_to_nil(project_value(project, :repo_ref)),
      repos: project_value(project, :repos) || [],
      workflow_file: blank_to_nil(project_value(project, :workflow_file)),
      assignee_filter: assignee_filter(assignee)
    }
  end

  defp project_value(project, key) when is_map(project) and is_atom(key) do
    Map.get(project, key) || Map.get(project, Atom.to_string(key))
  end

  defp project_value(_project, _key), do: nil

  defp project_key(_slug, _name, _project_id, true), do: nil

  defp project_key(slug, name, project_id, _legacy?) do
    [slug, name, project_id]
    |> Enum.find_value(&normalized_project_key/1)
  end

  defp normalized_project_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      value ->
        value
        |> String.upcase()
        |> String.replace(~r/[^A-Z0-9._-]/, "-")
        |> String.trim("-")
        |> blank_to_nil()
    end
  end

  defp normalized_project_key(_value), do: nil

  defp issue_identifier(identifier, %{key: key}) when is_binary(identifier) and is_binary(key) do
    "#{key}-#{identifier}"
  end

  defp issue_identifier(identifier, _project), do: identifier

  defp task_source_repo_key(task), do: task_routing_value(task, ["source_repo_key", "repo_key", "repo_slug"])
  defp task_source_repo_keys(task), do: task_routing_value(task, ["source_repo_keys", "repo_keys", "repo_slugs"])
  defp task_source_repo_url(task), do: task_routing_value(task, ["source_repo_url", "repo_url", "repo"])
  defp task_source_repo_ref(task), do: task_routing_value(task, ["source_repo_ref", "repo_ref", "ref"])
  defp task_workflow_file(task), do: task_routing_value(task, ["workflow_file", "workflow"])

  defp select_project_repos(task, project) do
    repos = project.repos || []
    explicit_url = task_source_repo_url(task)

    selected_repos =
      cond do
        is_binary(explicit_url) ->
          [repo_for_explicit_url(task, project)]

        requested_repo_keys(task) != [] ->
          select_requested_repos(repos, requested_repo_keys(task))

        true ->
          inferred_repos = infer_repos_from_task_text(task, repos)

          case inferred_repos do
            [] -> [Enum.find(repos, &(repo_value(&1, "default") == true)) || List.first(repos) || repo_for_project(task, project)]
            inferred_repos -> inferred_repos
          end
      end

    selected_repos
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_selected_repo(&1, task, project))
    |> Enum.reject(&(repo_value(&1, "repo_url") == nil))
  end

  defp repo_for_explicit_url(task, project) do
    %{
      "key" => task_source_repo_key(task),
      "repo_url" => task_source_repo_url(task) || project.repo_url,
      "repo_ref" => task_source_repo_ref(task) || project.repo_ref,
      "workflow_file" => task_workflow_file(task) || project.workflow_file
    }
  end

  defp repo_for_project(task, project) do
    %{
      "repo_url" => project.repo_url,
      "repo_ref" => task_source_repo_ref(task) || project.repo_ref,
      "workflow_file" => task_workflow_file(task) || project.workflow_file
    }
  end

  defp requested_repo_keys(task) do
    [task_source_repo_key(task) | split_repo_keys(task_source_repo_keys(task))]
    |> Enum.map(&normalize_repo_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp split_repo_keys(value) when is_binary(value) do
    value
    |> String.split([",", "\n", "\t", " "], trim: true)
  end

  defp split_repo_keys(_value), do: []

  defp select_requested_repos(repos, requested_keys) when is_list(repos) do
    Enum.flat_map(requested_keys, fn requested_key ->
      repos
      |> Enum.find(&(repo_value(&1, "key") |> normalize_repo_key() == requested_key))
      |> List.wrap()
    end)
  end

  defp infer_repos_from_task_text(task, repos) when is_list(repos) do
    task_text =
      [task_field(task, "title"), task_field(task, "description")]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")
      |> String.downcase()

    Enum.filter(repos, fn repo ->
      repo_key = repo_value(repo, "key")
      repo_name = repo_value(repo, "name")

      Enum.any?([repo_key, repo_name], fn value ->
        case normalize_repo_search_term(value) do
          nil -> false
          term -> String.contains?(task_text, term)
        end
      end)
    end)
  end

  defp infer_repos_from_task_text(_task, _repos), do: []

  defp normalize_repo_search_term(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> blank_to_nil()
  end

  defp normalize_repo_search_term(_value), do: nil

  defp normalize_selected_repo(repo, task, project) do
    %{
      "key" => repo_value(repo, "key"),
      "name" => repo_value(repo, "name"),
      "repo_url" => repo_value(repo, "repo_url") || project.repo_url,
      "repo_ref" => task_source_repo_ref(task) || repo_value(repo, "repo_ref") || project.repo_ref,
      "workflow_file" => task_workflow_file(task) || repo_value(repo, "workflow_file") || project.workflow_file
    }
  end

  defp repo_value(repo, key) when is_map(repo) and is_binary(key) do
    Map.get(repo, key) || Map.get(repo, String.to_atom(key))
  end

  defp repo_value(_repo, _key), do: nil

  defp normalize_repo_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> blank_to_nil()
  end

  defp normalize_repo_key(_value), do: nil

  defp task_routing_value(task, keys) when is_map(task) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      task_field(task, key) || description_routing_value(task_field(task, "description"), key)
    end)
  end

  defp description_routing_value(description, key) when is_binary(description) and is_binary(key) do
    env_key = key |> String.upcase()
    label = key |> String.replace("_", "[-_ ]?")

    [
      ~r/(?:^|\n)\s*#{Regex.escape(env_key)}\s*=\s*(?<value>\S+)/,
      ~r/(?:^|\n)\s*#{label}\s*:\s*(?<value>\S+)/i
    ]
    |> Enum.find_value(fn regex ->
      case Regex.named_captures(regex, description) do
        %{"value" => value} -> blank_to_nil(String.trim(value))
        _ -> nil
      end
    end)
  end

  defp description_routing_value(_description, _key), do: nil

  defp assignee_filter(nil), do: nil

  defp assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil -> nil
      normalized -> %{configured_assignee: assignee, match_values: MapSet.new([normalized])}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

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

defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :project_id,
    :project_name,
    :project_slug,
    :project_key,
    :tracker_identifier,
    :source_repo_key,
    :source_repo_url,
    :source_repo_ref,
    :workflow_file,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          project_id: String.t() | nil,
          project_name: String.t() | nil,
          project_slug: String.t() | nil,
          project_key: String.t() | nil,
          tracker_identifier: String.t() | nil,
          source_repo_key: String.t() | nil,
          source_repo_url: String.t() | nil,
          source_repo_ref: String.t() | nil,
          workflow_file: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end

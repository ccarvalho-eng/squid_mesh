defmodule MinimalHostApp.Steps.FailOnce do
  @moduledoc """
  Example step that fails once per run and succeeds on the next attempt.

  The production-readiness harness uses this step to verify Squid Mesh retry
  semantics without depending on transport-level retry behavior in external
  clients.
  """

  use Jido.Action,
    name: "fail_once",
    description: "Fails once per run and then succeeds",
    schema: [
      attempt_id: [type: :string, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, map()}
  def run(%{attempt_id: attempt_id}, %{run_id: run_id}) when is_binary(run_id) do
    key = {__MODULE__, run_id}

    case :persistent_term.get(key, :first_attempt) do
      :first_attempt ->
        :persistent_term.put(key, :retried)
        {:error, %{message: "retry later", code: "retry_later"}}

      :retried ->
        :persistent_term.erase(key)
        {:ok, %{retry_probe: %{attempt_id: attempt_id, status: "ok"}}}
    end
  end
end

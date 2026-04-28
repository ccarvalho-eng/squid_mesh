defmodule SquidMesh.TestSupport.FakeRepo do
  @moduledoc false

  use Agent

  alias Ecto.Changeset
  alias SquidMesh.Persistence.Run, as: RunRecord

  @rollback_tag :fake_repo_rollback

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _state -> %{} end)
  end

  @spec transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    catch
      {@rollback_tag, reason} -> {:error, reason}
    end
  end

  @spec rollback(term()) :: no_return()
  def rollback(reason), do: throw({@rollback_tag, reason})

  @spec insert(Changeset.t()) :: {:ok, struct()} | {:error, Changeset.t()}
  def insert(%Changeset{} = changeset) do
    case Changeset.apply_action(changeset, :insert) do
      {:ok, struct} ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        record =
          struct
          |> ensure_id()
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)

        Agent.update(__MODULE__, &Map.put(&1, {record.__struct__, record.id}, record))

        {:ok, record}

      {:error, %Changeset{} = invalid_changeset} ->
        {:error, invalid_changeset}
    end
  end

  @spec update(Changeset.t()) :: {:ok, struct()} | {:error, Changeset.t()}
  def update(%Changeset{} = changeset) do
    case Changeset.apply_action(changeset, :update) do
      {:ok, struct} ->
        key = {struct.__struct__, struct.id}

        Agent.get_and_update(__MODULE__, fn state ->
          existing = Map.fetch!(state, key)

          updated_record = %{
            struct
            | inserted_at: existing.inserted_at,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          }

          {{:ok, updated_record}, Map.put(state, key, updated_record)}
        end)

      {:error, %Changeset{} = invalid_changeset} ->
        {:error, invalid_changeset}
    end
  end

  @spec get(module(), Ecto.UUID.t()) :: struct() | nil
  def get(schema, id) do
    Agent.get(__MODULE__, &Map.get(&1, {schema, id}))
  end

  @spec list_runs(keyword()) :: [RunRecord.t()]
  def list_runs(filters) do
    Agent.get(__MODULE__, fn state ->
      state
      |> Map.values()
      |> Enum.filter(&match?(%RunRecord{}, &1))
      |> filter_runs(filters)
      |> Enum.sort(&run_desc?/2)
      |> limit_runs(filters)
    end)
  end

  @spec update_run_status!(Ecto.UUID.t(), String.t()) :: RunRecord.t()
  def update_run_status!(run_id, status) when is_binary(status) do
    Agent.get_and_update(__MODULE__, fn state ->
      key = {RunRecord, run_id}
      run = Map.fetch!(state, key)

      updated_run = %{
        run
        | status: status,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      {updated_run, Map.put(state, key, updated_run)}
    end)
  end

  defp ensure_id(%{id: nil} = struct), do: %{struct | id: Ecto.UUID.generate()}
  defp ensure_id(struct), do: struct

  defp filter_runs(runs, filters) do
    Enum.reduce(filters, runs, fn
      {:workflow, workflow}, acc ->
        Enum.filter(acc, &(&1.workflow == workflow))

      {:status, status}, acc ->
        Enum.filter(acc, &(&1.status == status))

      {_other_key, _other_value}, acc ->
        acc
    end)
  end

  defp limit_runs(runs, filters) do
    case Keyword.get(filters, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(runs, limit)
      _ -> runs
    end
  end

  defp run_desc?(left, right) do
    case DateTime.compare(left.inserted_at, right.inserted_at) do
      :gt -> true
      :lt -> false
      :eq -> left.id >= right.id
    end
  end
end

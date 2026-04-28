defmodule SquidMesh.TestSupport.FakeRepo do
  @moduledoc false

  use Agent

  alias Ecto.Changeset

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

  @spec get(module(), Ecto.UUID.t()) :: struct() | nil
  def get(schema, id) do
    Agent.get(__MODULE__, &Map.get(&1, {schema, id}))
  end

  defp ensure_id(%{id: nil} = struct), do: %{struct | id: Ecto.UUID.generate()}
  defp ensure_id(struct), do: struct
end

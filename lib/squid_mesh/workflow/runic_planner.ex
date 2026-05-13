defmodule SquidMesh.Workflow.RunicPlanner do
  @moduledoc false

  alias Runic.Workflow
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced}
  alias Runic.Workflow.{Fact, Invokable}
  alias SquidMesh.Workflow.Info
  alias SquidMesh.Workflow.RunicPlanner.Runnable
  alias SquidMesh.Workflow.Spec

  @max_phash 4_294_967_296
  @no_input {:squid_mesh, :no_planner_input}

  @type t :: %__MODULE__{
          spec: Spec.t(),
          runic_workflow: Workflow.t()
        }

  defstruct [:spec, :runic_workflow]

  @doc """
  Builds a planner from a compiled Squid Mesh workflow module.
  """
  @spec new(module() | Spec.t()) :: {:ok, t()} | {:error, term()}
  def new(workflow) when is_atom(workflow) do
    with {:ok, spec} <- Info.fetch_spec(workflow) do
      new(spec)
    end
  end

  def new(%Spec{} = spec) do
    {:ok, %__MODULE__{spec: spec, runic_workflow: build_runic_workflow(spec)}}
  end

  @doc """
  Plans from existing planner facts and returns externally executable steps.
  """
  @spec plan(t()) :: {:ok, t(), [Runnable.t()]}
  def plan(%__MODULE__{} = planner), do: plan(planner, @no_input)

  @doc """
  Adds a new durable input fact, plans through Runic, and returns runnable steps.
  """
  @spec plan(t(), term()) :: {:ok, t(), [Runnable.t()]}
  def plan(%__MODULE__{} = planner, input) do
    workflow =
      case input do
        @no_input -> Workflow.plan_eagerly(planner.runic_workflow)
        value -> Workflow.plan_eagerly(planner.runic_workflow, value)
      end

    prepare_external_runnables(%{planner | runic_workflow: workflow})
  end

  @doc """
  Applies the result of an externally executed Squid Mesh runnable.
  """
  @spec apply_result(t(), Runnable.t(), {:ok, term()} | {:error, term()}) ::
          {:ok, t()}
  def apply_result(
        %__MODULE__{} = planner,
        %Runnable{runic_runnable: %Runic.Workflow.Runnable{} = runic_runnable},
        {:ok, result}
      ) do
    completed = complete_runic_runnable(runic_runnable, result)
    {:ok, %{planner | runic_workflow: Workflow.apply_runnable(planner.runic_workflow, completed)}}
  end

  def apply_result(
        %__MODULE__{} = planner,
        %Runnable{runic_runnable: %Runic.Workflow.Runnable{} = runic_runnable},
        {:error, reason}
      ) do
    failed = Runic.Workflow.Runnable.fail(runic_runnable, reason)
    {:ok, %{planner | runic_workflow: Workflow.apply_runnable(planner.runic_workflow, failed)}}
  end

  @doc false
  def external_step_result(input), do: input

  defp build_runic_workflow(%Spec{} = spec) do
    parent_map = parent_map(spec)
    step_map = Map.new(spec.steps, &{&1.name, &1})

    spec
    |> ordered_steps(parent_map, step_map)
    |> Enum.reduce(Workflow.new(spec.workflow), fn step, workflow ->
      add_runic_step(workflow, spec, step, Map.get(parent_map, step.name, []))
    end)
  end

  defp add_runic_step(workflow, spec, step, []) do
    Workflow.add(workflow, runic_step(spec, step), validate: :off)
  end

  defp add_runic_step(workflow, spec, step, [parent]) do
    Workflow.add(workflow, runic_step(spec, step), to: parent, validate: :off)
  end

  defp add_runic_step(workflow, spec, step, parents) when is_list(parents) do
    Workflow.add(workflow, runic_step(spec, step), to: parents, validate: :off)
  end

  defp runic_step(spec, step) do
    Runic.Workflow.Step.new(
      work: &__MODULE__.external_step_result/1,
      name: step.name,
      hash: stable_step_hash(spec, step),
      inputs: nil,
      outputs: nil
    )
  end

  defp stable_step_hash(spec, step) do
    :erlang.phash2({:squid_mesh_step, spec.workflow, step.name, step.module}, @max_phash)
  end

  defp parent_map(%Spec{} = spec) do
    transition_parents =
      Enum.reduce(spec.transitions, %{}, fn
        %{from: from, on: :ok, to: to}, acc when is_atom(to) ->
          Map.update(acc, to, [from], fn parents -> parents ++ [from] end)

        _transition, acc ->
          acc
      end)

    Map.new(spec.steps, fn step ->
      parents =
        case Keyword.get(step.opts, :after) do
          dependencies when is_list(dependencies) -> dependencies
          _other -> Map.get(transition_parents, step.name, [])
        end

      {step.name, parents}
    end)
  end

  defp ordered_steps(%Spec{} = spec, parent_map, step_map) do
    {steps, _visiting, _visited} =
      Enum.reduce(spec.steps, {[], MapSet.new(), MapSet.new()}, fn step, acc ->
        visit_step(step.name, parent_map, step_map, acc)
      end)

    Enum.reverse(steps)
  end

  defp visit_step(step_name, parent_map, step_map, {ordered, visiting, visited})
       when is_atom(step_name) do
    if MapSet.member?(visited, step_name) or MapSet.member?(visiting, step_name) do
      {ordered, visiting, visited}
    else
      do_visit_step(step_name, parent_map, step_map, {ordered, visiting, visited})
    end
  end

  defp do_visit_step(step_name, parent_map, step_map, {ordered, visiting, visited}) do
    visiting = MapSet.put(visiting, step_name)

    {ordered, visiting, visited} =
      parent_map
      |> Map.get(step_name, [])
      |> Enum.reduce({ordered, visiting, visited}, fn parent, acc ->
        visit_step(parent, parent_map, step_map, acc)
      end)

    step = Map.fetch!(step_map, step_name)

    {
      [step | ordered],
      MapSet.delete(visiting, step_name),
      MapSet.put(visited, step_name)
    }
  end

  defp prepare_external_runnables(%__MODULE__{} = planner) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(planner.runic_workflow)
    {external, internal} = Enum.split_with(runnables, &external_runnable?(&1, planner.spec))

    if internal == [] do
      planner = %{planner | runic_workflow: workflow}
      {:ok, planner, Enum.map(external, &to_squid_mesh_runnable(&1, planner.spec))}
    else
      workflow =
        Enum.reduce(internal, workflow, fn runic_runnable, acc ->
          executed = Invokable.execute(runic_runnable.node, runic_runnable)
          Workflow.apply_runnable(acc, executed)
        end)

      planner
      |> then(&%{&1 | runic_workflow: Workflow.plan_eagerly(workflow)})
      |> prepare_external_runnables()
    end
  end

  defp external_runnable?(%Runic.Workflow.Runnable{node: %{name: name}}, %Spec{} = spec) do
    Enum.any?(spec.steps, &(&1.name == name))
  end

  defp external_runnable?(_runnable, _spec), do: false

  defp to_squid_mesh_runnable(%Runic.Workflow.Runnable{} = runic_runnable, %Spec{} = spec) do
    step = Enum.find(spec.steps, &(&1.name == runic_runnable.node.name))

    %Runnable{
      id: runic_runnable.id,
      step: step.name,
      input: normalize_step_input(runic_runnable.input_fact.value),
      metadata: Map.get(step, :metadata, %{}),
      runic_runnable: runic_runnable
    }
  end

  defp normalize_step_input(values) when is_list(values) do
    if Enum.all?(values, &is_map/1) do
      Enum.reduce(values, %{}, &Map.merge(&2, &1))
    else
      values
    end
  end

  defp normalize_step_input(value), do: value

  defp complete_runic_runnable(%Runic.Workflow.Runnable{} = runic_runnable, result) do
    node = runic_runnable.node
    input_fact = runic_runnable.input_fact
    context = runic_runnable.context
    result_fact = Fact.new(value: result, ancestry: {node.hash, input_fact.hash})

    events = [
      %FactProduced{
        hash: result_fact.hash,
        value: result_fact.value,
        ancestry: result_fact.ancestry,
        producer_label: :produced,
        weight: context.ancestry_depth + 1
      },
      %ActivationConsumed{
        fact_hash: input_fact.hash,
        node_hash: node.hash,
        from_label: :runnable
      }
    ]

    Runic.Workflow.Runnable.complete(runic_runnable, result_fact, events)
  end
end

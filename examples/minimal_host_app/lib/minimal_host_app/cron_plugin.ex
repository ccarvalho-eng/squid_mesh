defmodule MinimalHostApp.CronPlugin do
  @moduledoc """
  Host-owned Oban cron plugin for the example app's Squid Mesh workflows.
  """

  @behaviour Oban.Plugin

  use Supervisor

  alias MinimalHostApp.SquidMeshExecutor
  alias MinimalHostApp.Workers.SquidMeshWorker
  alias SquidMesh.Executor.Payload
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type option ::
          Oban.Plugin.option()
          | {:workflows, [module()]}

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts), do: super(opts)

  @impl Oban.Plugin
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl Oban.Plugin
  @spec validate([option()]) :: :ok | {:error, String.t()}
  def validate(opts) do
    workflows = Keyword.get(opts, :workflows)

    cond do
      not is_list(workflows) or workflows == [] ->
        {:error, "expected :workflows to be a non-empty list"}

      not Enum.all?(workflows, &is_atom/1) ->
        {:error, "expected :workflows to contain only workflow modules"}

      true ->
        validate_workflows(workflows)
    end
  end

  @spec evaluate(Supervisor.supervisor()) :: :ok
  def evaluate(plugin) do
    plugin
    |> Supervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> send(pid, :evaluate)
      _other -> :ok
    end)

    :ok
  end

  @impl Supervisor
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)
    workflows = Keyword.fetch!(opts, :workflows)

    children =
      workflows
      |> build_crontabs(SquidMeshExecutor.queue())
      |> Enum.map(fn {timezone, crontab} ->
        opts = [conf: conf, crontab: crontab, timezone: timezone]
        Supervisor.child_spec({Oban.Plugins.Cron, opts}, id: {:cron, timezone})
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp validate_workflows(workflows) do
    case Enum.reduce_while(workflows, :ok, &validate_workflow/2) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_workflow(workflow, :ok) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow) do
      case cron_triggers(definition) do
        [] ->
          {:halt, {:error, "workflow #{inspect(workflow)} must define a cron trigger"}}

        triggers ->
          validate_cron_triggers(workflow, triggers)
      end
    else
      {:error, {:invalid_workflow, _reason}} ->
        {:halt, {:error, "invalid workflow #{inspect(workflow)}"}}
    end
  end

  defp validate_cron_triggers(workflow, triggers) do
    case Enum.reduce_while(triggers, :ok, &validate_cron_trigger(workflow, &1, &2)) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp validate_cron_trigger(workflow, trigger, :ok) do
    %{name: trigger_name, config: %{expression: expression, timezone: timezone}} = trigger

    with {:ok, _payload} <- WorkflowDefinition.resolve_payload(trigger, %{}),
         :ok <- validate_crontab_entry(workflow, trigger_name, expression, timezone) do
      {:cont, :ok}
    else
      {:error, {:invalid_payload, _details}} ->
        {:halt,
         {:error, "cron workflow #{inspect(workflow)} must resolve its payload from defaults"}}

      _other ->
        {:halt, {:error, "workflow #{inspect(workflow)} must define one valid cron trigger"}}
    end
  end

  defp validate_crontab_entry(workflow, trigger_name, expression, timezone) do
    opts = [args: Payload.cron(workflow, trigger_name)]

    case Oban.Plugins.Cron.validate(
           crontab: [{expression, SquidMeshWorker, opts}],
           timezone: timezone
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_crontabs(workflows, queue) do
    workflows
    |> Enum.flat_map(&build_entries(&1, queue))
    |> Enum.group_by(fn {timezone, _entry} -> timezone end, fn {_timezone, entry} -> entry end)
    |> Enum.sort_by(fn {timezone, _entries} -> timezone end)
  end

  defp build_entries(workflow, queue) do
    {:ok, definition} = WorkflowDefinition.load(workflow)

    Enum.map(cron_triggers(definition), fn trigger ->
      entry = {
        trigger.config.expression,
        SquidMeshWorker,
        [args: Payload.cron(workflow, trigger.name), queue: queue]
      }

      {trigger.config.timezone, entry}
    end)
  end

  defp cron_triggers(definition) do
    Enum.filter(definition.triggers, &(&1.type == :cron))
  end
end

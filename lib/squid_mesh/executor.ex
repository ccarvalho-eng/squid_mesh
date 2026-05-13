defmodule SquidMesh.Executor do
  @moduledoc """
  Behaviour implemented by host applications to deliver Squid Mesh work.

  Squid Mesh owns workflow state, retry decisions, and progression. The host
  executor owns how runnable work is queued and later delivered back to the
  runtime entrypoints in `SquidMesh.Runtime.Runner`.
  """

  alias SquidMesh.Config
  alias SquidMesh.Run

  @type metadata :: map()
  @type enqueue_error :: term()
  @type enqueue_opts :: keyword()

  @callback enqueue_step(Config.t(), Run.t(), atom(), enqueue_opts()) ::
              {:ok, metadata()} | {:error, enqueue_error()}

  @callback enqueue_steps(Config.t(), Run.t(), [atom()], enqueue_opts()) ::
              {:ok, [metadata()]} | {:error, enqueue_error()}

  @callback enqueue_compensation(Config.t(), Run.t(), enqueue_opts()) ::
              {:ok, metadata()} | {:error, enqueue_error()}

  @callback enqueue_cron(Config.t(), module(), atom(), enqueue_opts()) ::
              {:ok, metadata()} | {:error, enqueue_error()}

  @required_callbacks [
    enqueue_step: 4,
    enqueue_steps: 4,
    enqueue_compensation: 3,
    enqueue_cron: 4
  ]

  @doc false
  @spec required_callbacks() :: keyword(pos_integer())
  def required_callbacks, do: @required_callbacks
end

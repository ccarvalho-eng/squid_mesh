defmodule MinimalHostApp.Smoke do
  @moduledoc """
  Repeatable smoke-test entrypoint for the example host app.
  """

  alias Ecto.Adapters.Postgres
  alias MinimalHostApp.Cron
  alias MinimalHostApp.WorkflowRuns

  @poll_attempts 20
  @poll_interval_ms 50

  @spec run!() :: SquidMesh.Run.t()
  def run! do
    ensure_runtime_started()
    {_server_pid, port} = start_gateway_server()

    attrs = %{
      account_id: "acct_demo",
      invoice_id: "inv_demo",
      attempt_id: "attempt_demo",
      gateway_url: endpoint_url(port, "/gateway")
    }

    with {:ok, run} <- WorkflowRuns.start_payment_recovery(attrs),
         :ok <- wait_for_execution(),
         {:ok, inspected_run} <- await_terminal_run(run.id, @poll_attempts) do
      IO.puts("started run #{run.id} for #{inspect(run.workflow)}")

      unless inspected_run.id == run.id and inspected_run.status == :completed do
        raise "unexpected smoke result"
      end

      inspected_run
    else
      {:error, reason} ->
        raise "smoke test failed: #{inspect(reason)}"
    end
  end

  @spec run_all!() :: %{payment_recovery: SquidMesh.Run.t(), daily_digest: SquidMesh.Run.t()}
  def run_all! do
    payment_recovery = run!()

    with :ok <- run_cron_digest(),
         {:ok, [cron_run]} <- WorkflowRuns.list_daily_digest_runs() do
      unless cron_run.status == :completed and cron_run.trigger == :daily_digest do
        raise "unexpected cron smoke result"
      end

      %{
        payment_recovery: payment_recovery,
        daily_digest: cron_run
      }
    else
      {:error, reason} ->
        raise "cron smoke test failed: #{inspect(reason)}"
    end
  end

  @spec run_cancellation!() :: SquidMesh.Run.t()
  def run_cancellation! do
    ensure_runtime_started()

    case run_cancellation_smoke() do
      {:ok, cancelled_run} ->
        cancelled_run

      {:error, reason} ->
        raise "cancellation smoke test failed: #{inspect(reason)}"
    end
  end

  @spec wait_for_execution() :: :ok
  defp wait_for_execution do
    if manual_oban_testing?() do
      _result = Oban.drain_queue(queue: :squid_mesh, with_recursion: true)
      :ok
    else
      :ok
    end
  end

  @spec run_cron_digest() :: :ok
  defp run_cron_digest do
    Cron.evaluate!()
    wait_for_execution()
  end

  @spec run_cancellation_smoke() :: {:ok, SquidMesh.Run.t()} | {:error, term()}
  defp run_cancellation_smoke do
    with {:ok, run} <- WorkflowRuns.start_cancellable_wait(%{account_id: "acct_demo"}),
         :ok <- wait_for_execution(),
         {:ok, cancelling_run} <- WorkflowRuns.cancel_run(run.id),
         :ok <- ensure_cancelling(cancelling_run),
         :ok <-
           SquidMesh.Workers.StepWorker.perform(%Oban.Job{
             args: %{"run_id" => run.id, "step" => "record_delivery"}
           }),
         {:ok, cancelled_run} <- await_terminal_run(run.id, @poll_attempts) do
      {:ok, cancelled_run}
    else
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  @spec ensure_cancelling(SquidMesh.Run.t()) :: :ok | {:error, :unexpected_cancellation_status}
  defp ensure_cancelling(%SquidMesh.Run{status: :cancelling}), do: :ok
  defp ensure_cancelling(%SquidMesh.Run{}), do: {:error, :unexpected_cancellation_status}

  @spec await_terminal_run(Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, SquidMesh.Run.t()} | {:error, term()}
  defp await_terminal_run(run_id, attempts_remaining)

  defp await_terminal_run(run_id, attempts_remaining) when attempts_remaining > 0 do
    case WorkflowRuns.inspect_run(run_id) do
      {:ok, run} when run.status in [:completed, :failed, :cancelled] ->
        {:ok, run}

      {:ok, _run} ->
        Process.sleep(@poll_interval_ms)
        await_terminal_run(run_id, attempts_remaining - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_terminal_run(_run_id, 0), do: {:error, :timeout}

  @spec endpoint_url(pos_integer(), String.t()) :: String.t()
  defp endpoint_url(port, path) do
    "http://127.0.0.1:#{port}#{path}"
  end

  @spec start_gateway_server() :: {pid(), pos_integer()}
  defp start_gateway_server do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(socket)

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, client} = :gen_tcp.accept(socket)
        _request = :gen_tcp.recv(client, 0)
        response = "HTTP/1.1 200 OK\r\ncontent-length: 14\r\n\r\nretry_required"
        :ok = :gen_tcp.send(client, response)
        :gen_tcp.close(client)
        :gen_tcp.close(socket)
      end)

    {pid, port}
  end

  @spec manual_oban_testing?() :: boolean()
  defp manual_oban_testing? do
    case Application.fetch_env(:minimal_host_app, Oban) do
      {:ok, config} -> Keyword.get(config, :testing) == :manual
      :error -> false
    end
  end

  @spec ensure_runtime_started() :: :ok
  defp ensure_runtime_started do
    ensure_repo_started()
    ensure_migrated()
    ensure_oban_started()
    :ok
  end

  @spec ensure_repo_started() :: :ok
  defp ensure_repo_started do
    if is_nil(Process.whereis(MinimalHostApp.Repo)) do
      repo_config = repo_config()

      case Postgres.storage_up(repo_config) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, term} -> raise "failed to create smoke database: #{inspect(term)}"
      end

      {:ok, _pid} = MinimalHostApp.Repo.start_link()
    end

    :ok
  end

  @spec ensure_migrated() :: :ok
  defp ensure_migrated do
    Ecto.Migrator.with_repo(MinimalHostApp.Repo, fn repo ->
      Ecto.Migrator.run(repo, app_migrations_path(), :up, all: true)
      Ecto.Migrator.run(repo, library_migrations_path(), :up, all: true)
    end)

    :ok
  end

  @spec app_migrations_path() :: String.t()
  defp app_migrations_path do
    Application.app_dir(:minimal_host_app, "priv/repo/migrations")
  end

  @spec library_migrations_path() :: String.t()
  defp library_migrations_path do
    Application.app_dir(:squid_mesh, "priv/repo/migrations")
  end

  @spec ensure_oban_started() :: :ok
  defp ensure_oban_started do
    oban_config = Application.fetch_env!(:minimal_host_app, Oban)
    oban_name = Keyword.get(oban_config, :name, Oban)

    if is_nil(Process.whereis(oban_name)) do
      case Oban.start_link(oban_config) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  @spec repo_config() :: keyword()
  defp repo_config do
    maybe_put = fn config, key, value ->
      if is_nil(value), do: config, else: Keyword.put(config, key, value)
    end

    :minimal_host_app
    |> Application.fetch_env!(MinimalHostApp.Repo)
    |> then(fn config ->
      case Keyword.fetch(config, :url) do
        {:ok, url} ->
          uri = URI.parse(url)

          {username, password} =
            case String.split(uri.userinfo || "", ":", parts: 2) do
              [user, pass] -> {user, pass}
              [user] -> {user, nil}
              _other -> {nil, nil}
            end

          database = String.trim_leading(uri.path || "", "/")

          config
          |> Keyword.delete(:url)
          |> Keyword.put(:hostname, uri.host)
          |> Keyword.put(:port, uri.port || 5432)
          |> Keyword.put(:database, database)
          |> maybe_put.(:username, username)
          |> maybe_put.(:password, password)

        :error ->
          config
      end
    end)
  end
end

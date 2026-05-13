defmodule MinimalHostApp.Cron do
  @moduledoc """
  Test and smoke helper for the example app's cron plugin.

  Oban's manual testing mode disables plugins, so the example harness starts the
  same host-owned cron plugin explicitly against the running Oban config.
  """

  @plugin_name __MODULE__.Plugin

  @spec ensure_started!() :: :ok
  def ensure_started! do
    if is_nil(Process.whereis(@plugin_name)) do
      oban_config = build_oban_config()
      plugin_opts = plugin_opts()

      case MinimalHostApp.CronPlugin.start_link(
             Keyword.merge(plugin_opts, conf: oban_config, name: @plugin_name)
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    else
      :ok
    end
  end

  @spec evaluate!() :: :ok
  def evaluate! do
    ensure_started!()
    MinimalHostApp.CronPlugin.evaluate(@plugin_name)
    Process.sleep(50)
  end

  defp plugin_opts do
    :minimal_host_app
    |> Application.fetch_env!(Oban)
    |> Keyword.get(:plugins, [])
    |> Enum.find_value([], fn
      {MinimalHostApp.CronPlugin, opts} -> opts
      _other -> false
    end)
  end

  defp build_oban_config do
    :minimal_host_app
    |> Application.fetch_env!(Oban)
    |> Keyword.put(:testing, :disabled)
    |> Keyword.put(:plugins, false)
    |> Keyword.put(:queues, false)
    |> Keyword.put(:peer, {Oban.Peers.Isolated, [leader?: true]})
    |> Oban.Config.new()
  end
end

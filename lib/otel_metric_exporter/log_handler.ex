defmodule OtelMetricExporter.LogHandler do
  @moduledoc """
  A Logger handler that forwards log events to OTel collector via OTLP protocol.

  This can be installed as a handler for the `:logger` application.

  Example:

      # Add and configure the handler
      config :my_app, :logger, [
        {:handler, OtelMetricExporter.LogHandler, :logger_std_h, %{
          config: %{
            metadata_map: %{
              request_id: "http.request.id"
            }
          },
        }}
      ]

      # Configure the resource and endpoint
      config :otel_metric_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint: otlp_endpoint,
        resource: %{
          name: "metrics",
          service: %{name: service_name, version: version},
          instance: %{id: instance_id}
        }

  It should then be explicitly attached by executing `Logger.add_handlers(:my_app)` in `Application.start/2` callback
  of your application.

  ## Options

  Options starting with `otlp_` and the `resource` option will be take automatically from the `:otel_metric_exporter`
  app configuration, but can be overridden when adding the handler.

  #{OtelMetricExporter.LogAccumulator.options_schema() |> NimbleOptions.docs()}
  """

  alias OtelMetricExporter.LogAccumulator
  alias OtelMetricExporter.LogHandlerSupervisor

  @behaviour :logger_handler

  @olp_config_keys [
    :drop_mode_qlen,
    :flush_qlen,
    :burst_limit_enable,
    :burst_limit_max_count,
    :burst_limit_window_time,
    :overload_kill_enable,
    :overload_kill_qlen,
    :overload_kill_mem_size,
    :overload_kill_restart_after
  ]

  @impl true
  def adding_handler(%{config: config} = handler_config) do
    {olp_config, accumulator_config} = Map.split(Map.new(config), @olp_config_keys)

    with {:ok, olp_config} <- prevalidate_olp(olp_config),
         {:ok, config} <- LogAccumulator.check_config(accumulator_config),
         {:ok, sup_pid, olp} <- start_supervisor(handler_config, config, olp_config) do
      olp_opts = :logger_olp.get_opts(olp)

      # Register the handler with the logger handler watcher, which detaches the handler
      # if it crashes for any reason to avoid taking down the entire logger process.
      :ok = :logger_handler_watcher.register_handler(handler_config.id, sup_pid)

      {:ok, %{handler_config | config: config |> Map.merge(olp_opts) |> Map.put(:olp, olp)}}
    end
  end

  defp prevalidate_olp(olp_config) do
    {:ok, Map.put(olp_config, :sync_mode_qlen, Map.get(olp_config, :drop_mode_qlen, 200))}
  end

  defp start_supervisor(handler_config, accumulator_config, olp_config) do
    Supervisor.start_child(
      :logger_sup,
      %{
        LogHandlerSupervisor.child_spec(
          name: :"#{handler_config.module}_#{handler_config.id}",
          accumulator_config: accumulator_config,
          olp_config: olp_config
        )
        | id: handler_config.id
      }
    )
  end

  @impl true
  def changing_config(set_or_update, %{config: %{olp: olp}} = old_config, new_config) do
    full_config =
      case set_or_update do
        :set ->
          new_config

        :update ->
          Map.merge(old_config, new_config, fn
            :config, v1, v2 -> Map.merge(v1, v2)
            _k, _v1, v2 -> v2
          end)
      end

    {olp_config, accumulator_config} = Map.split(full_config.config, @olp_config_keys)

    with {:ok, olp_config} <- prevalidate_olp(olp_config),
         {:ok, config} <- LogAccumulator.check_config(accumulator_config),
         :ok <- :logger_olp.set_opts(olp, olp_config) do
      :logger_olp.cast(olp, {:config_changed, config})
      {:ok, %{full_config | config: config |> Map.merge(olp_config)}}
    end
  end

  @impl true
  def filter_config(config) do
    config
  end

  @impl true
  def log(event, %{config: %{olp: olp} = config}) do
    true = Process.alive?(:logger_olp.get_pid(olp))
    :logger_olp.load(olp, LogAccumulator.prepare_log_event(event, config))
  end

  @impl true
  def removing_handler(handler_config) do
    supervisor_name = reg_name(handler_config, "Supervisor")

    case Process.whereis(supervisor_name) do
      nil ->
        :ok

      supervisor_pid ->
        # Stop the supervisor and all its children
        Supervisor.stop(supervisor_pid, :normal)
        :ok
    end
  end

  defp reg_name(prefix, part) when is_binary(prefix) or is_atom(prefix), do: :"#{prefix}_#{part}"
  defp reg_name(%{module: module, id: id}, part), do: :"#{module}_#{id}_#{part}"
end

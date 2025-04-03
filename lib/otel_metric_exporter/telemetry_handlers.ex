defmodule OtelMetricExporter.TelemetryHandlers do
  # Simple genserver that handles attaching the handler to the configured metrics
  # Ensures that metrics are attached **after** the MetricStore has started
  # and setup the generation_key system to avoid race conditions where
  # metrics are put before the MetricStore has started
  #
  # We could do the attach call in init and return :ignore
  # but this way we keep the handler ids around.
  use GenServer

  def name(%{name: stack_name}), do: :"#{stack_name}:TelemetryHandlers"

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: name(config))
  end

  @impl true
  def init(config) do
    handlers = setup_telemetry_handlers(config)

    {:ok, %{handlers: handlers}, :hibernate}
  end

  def setup_telemetry_handlers(config) do
    config.metrics
    |> Enum.group_by(& &1.event_name)
    |> Enum.map(fn {event_name, metrics} ->
      handler_id = {__MODULE__, config.name, event_name}

      :telemetry.attach(
        handler_id,
        event_name,
        &OtelMetricExporter.handle_metric/4,
        %{metrics: metrics, name: config.name}
      )

      handler_id
    end)
  end
end

defmodule OtelMetricExporter.LogHandlerSupervisor do
  @moduledoc false
  use Supervisor, shutdown: 10_000, restart: :temporary

  def fill_accumulator_config(accumulator_config, base_name) do
    accumulator_config
    |> Map.put(:finch, :"#{base_name}_Finch")
    |> Map.put(:task_supervisor, :"#{base_name}_TaskSupervisor")
  end

  def start_link(args) do
    base_name = args[:name]

    accumulator_config =
      args[:accumulator_config]

    olp_child_spec =
      logger_olp_child_spec(
        :"#{base_name}_logger_olp",
        accumulator_config,
        args[:olp_config]
      )

    with {:ok, sup_pid} <- Supervisor.start_link(__MODULE__, accumulator_config, name: base_name),
         {:ok, _, olp} <- Supervisor.start_child(sup_pid, olp_child_spec) do
      {:ok, sup_pid, olp}
    else
      {:error, {reason, child}} when is_tuple(child) and elem(child, 0) == :child ->
        {:error, reason}

      error ->
        error
    end
  end

  defp logger_olp_child_spec(reg_name, accumulator_config, olp_config) do
    %{
      id: :logger_olp,
      start:
        {:logger_olp, :start_link,
         [
           reg_name,
           OtelMetricExporter.LogAccumulator,
           accumulator_config,
           olp_config
         ]},
      restart: :temporary,
      significant: true,
      shutdown: 2000,
      type: :worker,
      modules: [OtelMetricExporter.LogAccumulator]
    }
  end

  @impl true
  def init(accumulator_config) do
    children = [
      {Finch,
       name: accumulator_config.api.finch,
       pools: %{
         :default => [size: accumulator_config.api.config.otlp_concurrent_requests, count: 1]
       }},
      {Task.Supervisor, name: accumulator_config.task_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :any_significant)
  end
end

defmodule OtelMetricExporter.LogHandlerSupervisor do
  @moduledoc false
  use Supervisor, shutdown: 10_000, restart: :temporary

  def start_link(args) do
    base_name = args[:name]

    accumulator_config =
      args[:accumulator_config]
      |> Map.put(:finch, :"#{base_name}_Finch")
      |> Map.put(:task_supervisor, :"#{base_name}_TaskSupervisor")

    case Supervisor.start_link(__MODULE__, accumulator_config, name: base_name) do
      {:ok, supervisor_pid} ->
        case Supervisor.start_child(
               supervisor_pid,
               logger_olp_child_spec(
                 :"#{base_name}_logger_olp",
                 accumulator_config,
                 args[:olp_config]
               )
             ) do
          {:ok, _, olp} ->
            {:ok, supervisor_pid, olp}

          {:error, {reason, child}} when is_tuple(child) and elem(child, 0) == :child ->
            {:error, reason}

          error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
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
      restart: :transient,
      significant: true,
      shutdown: 5000,
      type: :worker,
      modules: [OtelMetricExporter.LogAccumulator]
    }
  end

  @impl true
  def init(accumulator_config) do
    children = [
      {Finch,
       name: accumulator_config[:finch],
       pools: %{:default => [size: accumulator_config[:otlp_concurrent_requests], count: 1]}},
      {Task.Supervisor, name: accumulator_config[:task_supervisor]}
    ]

    Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :any_significant)
  end
end

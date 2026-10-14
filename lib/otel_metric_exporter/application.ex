defmodule OtelMetricExporter.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: OtelMetricExporter.Finch, pools: %{:default => [size: 10, count: 1]}}
    ]

    opts = [strategy: :one_for_one, name: OtelMetricExporter.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

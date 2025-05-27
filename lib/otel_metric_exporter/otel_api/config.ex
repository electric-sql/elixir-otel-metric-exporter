defmodule OtelMetricExporter.OtelApi.Config do
  require Logger

  defstruct [
    :otlp_endpoint,
    :otlp_protocol,
    :otlp_headers,
    :otlp_timeout,
    :exporter,
    :resource,
    :otlp_compression,
    :otlp_concurrent_requests
  ]

  @type protocol :: :http_protobuf
  @type compression :: :gzip | nil

  endpoint_opt = [
    otlp_endpoint: [
      type: :string,
      doc: "Endpoint to send data to."
    ]
  ]

  otlp_options =
    [
      otlp_protocol: [
        type: {:in, [:http_protobuf]},
        type_spec: quote(do: protocol()),
        default: :http_protobuf,
        doc: "Protocol to use for OTLP export. Currently only `:http_protobuf` is supported."
      ],
      otlp_headers: [
        type: {:map, :string, :string},
        default: %{},
        doc: "Headers to send with OTLP requests."
      ],
      otlp_timeout: [
        type: :pos_integer,
        default: 10_000,
        doc: "Timeout for OTLP requests."
      ]
    ]

  exporter_opt = [exporter: [type: {:in, [:otlp, :none]}, default: :otlp]]

  specific_option =
    for scope <- [:logs, :metrics] do
      {scope,
       [
         type: {:or, [:map, :keyword_list]},
         required: false,
         doc: "Overrides for #{scope}.",
         keys:
           Enum.map(endpoint_opt ++ otlp_options, fn {key, opts} ->
             {key, opts |> Keyword.delete(:default)}
           end) ++ exporter_opt
       ]}
    end

  top_level_opts = [
    otlp_compression: [
      type: {:in, [:gzip, nil]},
      default: :gzip,
      type_spec: quote(do: compression()),
      doc: "Compression to use for OTLP requests. Allowed values are `:gzip` and `nil`."
    ],
    otlp_concurrent_requests: [
      type: :non_neg_integer,
      default: 10,
      doc: "Number of concurrent requests to send to the OTLP endpoint."
    ],
    resource: [
      type: {:map, {:or, [:atom, :string]}, :any},
      default: %{},
      doc: "Resource attributes to send with collected data."
    ]
  ]

  @public_options endpoint_opt ++
                    otlp_options ++
                    specific_option ++ top_level_opts

  @options_schema NimbleOptions.new!(@public_options)

  @single_scope_schema NimbleOptions.new!(
                         [
                           otlp_endpoint: [
                             type: :string,
                             required: true,
                             doc: "Endpoint to send data to."
                           ]
                         ] ++ otlp_options ++ exporter_opt ++ top_level_opts
                       )

  def public_options(), do: @public_options
  def options_schema(), do: @options_schema

  defp defaults_from_env do
    base =
      %{}
      |> put_from_env("OTEL_EXPORTER_OTLP_ENDPOINT", :otlp_endpoint)
      |> put_from_env("OTEL_EXPORTER_OTLP_PROTOCOL", :otlp_protocol, &cast_otlp_protocol/1)
      |> put_from_env("OTEL_EXPORTER_OTLP_HEADERS", :otlp_headers, &cast_otlp_headers/1)
      |> put_from_env("OTEL_EXPORTER_OTLP_TIMEOUT", :otlp_timeout, &cast_otlp_timeout/1)

    for scope <- [:logs, :metrics], env_scope = String.upcase(to_string(scope)), reduce: base do
      acc ->
        acc
        |> Map.put(scope, %{})
        |> put_from_env("OTEL_EXPORTER_OTLP_#{env_scope}_ENDPOINT", [scope, :otlp_endpoint])
        |> put_from_env(
          "OTEL_EXPORTER_OTLP_#{env_scope}_PROTOCOL",
          [scope, :otlp_protocol],
          &cast_otlp_protocol/1
        )
        |> put_from_env(
          "OTEL_EXPORTER_OTLP_#{env_scope}_HEADERS",
          [scope, :otlp_headers],
          &cast_otlp_headers/1
        )
        |> put_from_env(
          "OTEL_EXPORTER_OTLP_#{env_scope}_TIMEOUT",
          [scope, :otlp_timeout],
          &cast_otlp_timeout/1
        )
        |> put_from_env("OTEL_#{env_scope}_EXPORTER", [scope, :exporter], &cast_otlp_exporter/1)
    end
    |> put_from_env("OTEL_RESOURCE_ATTRIBUTES", :resource, &cast_resource_attributes/1)
    |> Map.put_new(:resource, %{})
    |> put_from_env("OTEL_SERVICE_NAME", [:resource, "service.name"])
  end

  defp put_from_env(acc, env_var, key, cast_fun \\ fn x -> {:ok, x} end) do
    with {:ok, value} <- System.fetch_env(env_var),
         {:ok, casted} <- cast_fun.(value) do
      put_in(acc, List.wrap(key), casted)
    else
      :error ->
        acc

      {:error, message} ->
        Logger.warning("Invalid #{env_var} value, ignoring: #{message}")
        acc
    end
  end

  defp cast_otlp_protocol("http/json"), do: {:ok, :http_json}
  defp cast_otlp_protocol("http/protobuf"), do: {:ok, :http_protobuf}
  defp cast_otlp_protocol("grpc"), do: {:ok, :grpc}
  defp cast_otlp_protocol(other), do: {:error, "invalid OTLP protocol: #{inspect(other)}"}

  defp cast_otlp_headers(value) do
    {:ok,
     String.split(value, ",")
     |> Enum.map(&String.split(&1, "="))
     |> Map.new(fn [key, value] -> {key, value} end)}
  rescue
    FunctionClauseError ->
      {:error, "invalid OTLP headers: #{inspect(value)}"}
  end

  defp cast_otlp_timeout(value) do
    case Integer.parse(value) do
      {timeout, ""} when timeout > 0 -> {:ok, timeout}
      _ -> {:error, "invalid OTLP timeout: #{inspect(value)}"}
    end
  end

  defp cast_resource_attributes(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.split(&1, "="))
    |> Map.new(fn [key, value] -> {key, value} end)
    |> then(&{:ok, &1})
  rescue
    FunctionClauseError ->
      {:error, "invalid resource attributes: #{inspect(value)}"}
  end

  defp cast_otlp_exporter("otlp"), do: {:ok, :otlp}
  defp cast_otlp_exporter("none"), do: {:ok, :none}
  defp cast_otlp_exporter(_), do: {:error, "unsupported otlp exporter configuration"}

  def defaults do
    from_env =
      defaults_from_env()
      |> Map.take(Keyword.keys(@public_options))
      |> NimbleOptions.validate(options_schema())
      |> case do
        {:ok, validated} -> validated
        {:error, _} -> %{}
      end

    from_app =
      Application.get_all_env(:otel_metric_exporter)
      |> Map.new()
      |> Map.take(Keyword.keys(@public_options))
      |> Map.update(:resource, %{}, &normalize_resources/1)

    Map.merge(from_env, from_app, fn
      k, v1, v2 when k in [:logs, :metrics, :resource] -> Map.merge(Map.new(v1), Map.new(v2))
      _, _, v2 -> v2
    end)
    |> NimbleOptions.validate(options_schema())
  end

  def validate_for_scope(config, scope) when scope in [:logs, :metrics] do
    {provided, rest} = Map.split(config, Keyword.keys(@public_options) -- [:logs, :metrics])

    with {:ok, defaults} <- defaults() do
      with_overrides =
        defaults
        |> get_for_scope(scope)
        |> Map.merge(
          Map.update(provided, :resource, %{}, &normalize_resources/1),
          &if(&1 == :resource, do: Map.merge(&2, &3), else: &3)
        )

      case Map.get(with_overrides, :exporter) do
        x when x in [:otlp, nil] ->
          with {:ok, validated} <- NimbleOptions.validate(with_overrides, @single_scope_schema) do
            {:ok, struct!(__MODULE__, validated), rest}
          end

        :none ->
          {:ok, %__MODULE__{exporter: :none}, rest}
      end
    end
  end

  defp get_for_scope(config, scope),
    do: Map.merge(Map.drop(config, [:logs, :metrics]), config[scope] || %{})

  defp normalize_resources(resource_map), do: Map.new(do_normalize_resources(resource_map))

  defp do_normalize_resources(map, prefix \\ "") do
    Enum.flat_map(map, fn {key, value} ->
      if is_map(value) do
        do_normalize_resources(value, prefix <> to_string(key) <> ".")
      else
        [{prefix <> to_string(key), value}]
      end
    end)
  end
end

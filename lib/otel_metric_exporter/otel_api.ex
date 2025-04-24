defmodule OtelMetricExporter.OtelApi do
  @moduledoc false

  use Retry

  alias OtelMetricExporter.Protocol

  require Logger

  @type protocol :: :http_protobuf
  @type compression :: :gzip | nil

  @public_options [
    otlp_endpoint: [
      type: :string,
      required: true,
      doc: "Endpoint to send data to."
    ],
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
      type: :map,
      default: %{},
      doc: "Resource attributes to send with collected data."
    ]
  ]

  @schema NimbleOptions.new!(
            [
              finch: [
                type: {:or, [:atom, :pid]},
                required: true,
                doc: "Finch process pid or registered name to use for sending requests."
              ],
              retry: [
                type: :boolean,
                default: true,
                doc: "Retry HTTP requests when receiving a transient error"
              ]
            ] ++ @public_options
          )

  defstruct [:finch, :retry] ++ Keyword.keys(@public_options)

  def public_options, do: @public_options

  def defaults,
    do:
      Application.get_all_env(:otel_metric_exporter)
      |> Map.new()
      |> Map.take(Keyword.keys(@public_options))

  def new(opts) do
    {opts, rest} = Map.split(opts, Keyword.keys(@public_options) ++ [:finch, :retry])

    with {:ok, config} <- NimbleOptions.validate(Map.merge(defaults(), opts), @schema) do
      {:ok, struct!(__MODULE__, config), rest}
    end
  end

  def send_log_events(%__MODULE__{} = config, events) do
    events
    |> Protocol.build_log_service_request(config.resource)
    |> send_proto("/v1/logs", config)
  end

  def send_metrics(%__MODULE__{} = config, metrics) do
    metrics
    |> Protocol.build_metric_service_request(config.resource)
    |> send_proto("/v1/metrics", config)
  end

  @spec send_proto(struct(), String.t(), %__MODULE__{}) :: :ok | {:error, any()}
  defp send_proto(body, path, %__MODULE__{} = config) do
    body
    |> Protobuf.encode_to_iodata()
    |> build_finch_request(path, config)
    |> make_finch_request(config.finch, with_retry?: config.retry)
  end

  defp build_finch_request(body, path, %__MODULE__{} = config) do
    Finch.build(
      :post,
      url(config, path),
      Map.to_list(headers(config)),
      maybe_compress(body, config)
    )
  end

  defp make_finch_request(request, finch_pool, with_retry?: true) do
    retry with: exponential_backoff(1_000) |> randomize() |> expiry(20_000), atoms: [:retry] do
      case finch_request(request, finch_pool) do
        :ok ->
          :ok

        {:error, {:unexpected_status, %{status: status} = response} = reason}
        when status in [408, 429, 500, 502, 503, 504] ->
          Logger.warning(
            "Got transient error #{status} from server #{inspect(response)}, retrying...",
            request_path: request.path
          )

          {:retry, reason}

        {:error, {:unexpected_status, _response}} = permanent_error ->
          # This will be logged by the caller
          permanent_error

        {:error, reason} ->
          Logger.warning(
            "Got connection/transport error when sending metrics #{inspect(reason)}, retrying...",
            request_path: request.path
          )

          {:retry, reason}
      end
    else
      {:retry, reason} -> {:error, reason}
    end
  end

  defp make_finch_request(request, finch_pool, with_retry?: false) do
    finch_request(request, finch_pool)
  end

  defp finch_request(request, finch_pool) do
    request
    |> Finch.request(finch_pool)
    |> case do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, response} ->
        {:error, {:unexpected_status, response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp url(%__MODULE__{} = config, path), do: config.otlp_endpoint <> path

  defp headers(%__MODULE__{otlp_compression: compression} = config) do
    [:content_type, :accept, :compression]
    |> Enum.reduce(%{}, fn
      :content_type, acc -> Map.put(acc, "content-type", "application/x-protobuf")
      :accept, acc -> Map.put(acc, "accept", "application/x-protobuf")
      :compression, acc when compression == :gzip -> Map.put(acc, "content-encoding", "gzip")
      _, acc -> acc
    end)
    |> Map.merge(config.otlp_headers)
  end

  defp maybe_compress(body, %__MODULE__{otlp_compression: :gzip}), do: :zlib.gzip(body)
  defp maybe_compress(body, _), do: body
end

defmodule OtelMetricExporter.OtlpUtils do
  @moduledoc false

  alias OtelMetricExporter.Opentelemetry.Proto.Common.V1.{
    AnyValue,
    KeyValue,
    KeyValueList,
    ArrayValue
  }

  def build_kv(tags, key_prefix \\ "") do
    Enum.flat_map(tags, fn {key, value} ->
      if is_map(value) do
        build_kv(value, key_prefix <> to_string(key) <> ".")
      else
        [
          %KeyValue{
            key: key_prefix <> to_string(key),
            value: %AnyValue{value: to_kv_value(value)}
          }
        ]
      end
    end)
  end

  def to_kv_value(value) when is_binary(value), do: {:string_value, value}
  def to_kv_value(value) when is_atom(value), do: {:string_value, to_string(value)}
  def to_kv_value(value) when is_integer(value), do: {:int_value, value}
  def to_kv_value(value) when is_float(value), do: {:double_value, value}
  def to_kv_value(value) when is_boolean(value), do: {:bool_value, value}
  def to_kv_value(value) when is_struct(value), do: {:string_value, to_string(value)}

  def to_kv_value([{k, _} | _] = value) when is_atom(k),
    do: {:kvlist_value, %KeyValueList{values: build_kv(value)}}

  def to_kv_value(value) when is_list(value),
    do: {:array_value, %ArrayValue{values: Enum.map(value, &%AnyValue{value: to_kv_value(&1)})}}

  def to_kv_value(value) when is_tuple(value), do: to_kv_value(Tuple.to_list(value))
  def to_kv_value(value) when is_pid(value), do: to_kv_value(inspect(value))
  def to_kv_value(any), do: to_kv_value(inspect(any))
end

defmodule OtelMetricExporter.OtlpUtilsTest do
  use ExUnit.Case, async: true

  alias OtelMetricExporter.OtlpUtils

  describe "to_kv_value/1" do
    test "encodes booleans as bool_value, not as the strings \"true\" and \"false\"" do
      assert OtlpUtils.to_kv_value(true) == {:bool_value, true}
      assert OtlpUtils.to_kv_value(false) == {:bool_value, false}
    end

    test "still encodes other atoms as strings" do
      assert OtlpUtils.to_kv_value(:ok) == {:string_value, "ok"}
    end

    test "encodes a boolean inside a keyword list or a list" do
      assert {:kvlist_value, %{values: [%{key: "enabled", value: %{value: {:bool_value, true}}}]}} =
               OtlpUtils.to_kv_value(enabled: true)

      assert {:array_value, %{values: [%{value: {:bool_value, false}}]}} =
               OtlpUtils.to_kv_value([false])
    end
  end
end

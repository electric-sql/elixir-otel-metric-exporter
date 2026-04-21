defmodule OtelMetricExporter.LogAccumulatorTest do
  use ExUnit.Case, async: true

  alias OtelMetricExporter.LogAccumulator

  describe "handle_info/2" do
    test "ignores unexpected messages without crashing" do
      state = %{pending_tasks: %{}}

      assert {:noreply, ^state} = LogAccumulator.handle_info(:some_unexpected_message, state)
      assert {:noreply, ^state} = LogAccumulator.handle_info({:foo, :bar}, state)
      assert {:noreply, ^state} = LogAccumulator.handle_info({:EXIT, self(), :normal}, state)
    end

    test "ignores task reply with unknown ref without crashing" do
      state = %{pending_tasks: %{}}
      unknown_ref = make_ref()

      assert {:noreply, ^state} =
               LogAccumulator.handle_info({unknown_ref, {:ok, :done}}, state)
    end

    test "ignores DOWN message with unknown ref without crashing" do
      state = %{pending_tasks: %{}}
      unknown_ref = make_ref()

      assert {:noreply, ^state} =
               LogAccumulator.handle_info(
                 {:DOWN, unknown_ref, :process, self(), :normal},
                 state
               )
    end
  end
end

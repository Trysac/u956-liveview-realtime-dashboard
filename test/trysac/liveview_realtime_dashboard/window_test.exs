defmodule Trysac.LiveviewRealtimeDashboard.WindowTest do
  use ExUnit.Case, async: true

  alias Trysac.LiveviewRealtimeDashboard.Error
  alias Trysac.LiveviewRealtimeDashboard.Frame
  alias Trysac.LiveviewRealtimeDashboard.Summary
  alias Trysac.LiveviewRealtimeDashboard.Window

  doctest Window
  doctest Summary
  doctest Frame
  doctest Trysac.LiveviewRealtimeDashboard

  describe "Window.new/2 and Window.add/3 and Window.summary/2" do
    test "acceptance 1: values 1 to 10 added at 0, 1_000, ... 9_000 summarized at 9_500 and 65_000" do
      w = Window.new(60_000, 1_000)

      w =
        Enum.reduce(1..10, w, fn val, acc ->
          ts = (val - 1) * 1_000
          Window.add(acc, ts, val)
        end)

      s1 = Window.summary(w, 9_500)
      assert s1.count == 10
      assert s1.sum == 55
      assert s1.min == 1
      assert s1.max == 10
      assert s1.last == 10
      assert s1.rate_per_min == 10.0

      s2 = Window.summary(w, 65_000)
      assert s2.count == 4
      assert s2.sum == 34
      assert s2.min == 7
      assert s2.max == 10
      assert s2.last == 10
      assert s2.rate_per_min == 4.0
    end

    test "edge case: update exactly at the window edge" do
      w = Window.new(60_000, 1_000)
      w = Window.add(w, 0, 100)

      # Bucket [0, 1_000) has bucket_start = 0.
      # Active while bucket_start + window_ms > now_ms -> 60_000 > now_ms.
      s_before = Window.summary(w, 59_999)
      assert s_before.count == 1
      assert s_before.sum == 100

      s_exact = Window.summary(w, 60_000)
      assert s_exact.count == 0
      assert s_exact.sum == 0
      assert s_exact.min == nil
      assert s_exact.max == nil
      assert s_exact.last == 100
      assert s_exact.rate_per_min == 0.0
    end

    test "multiple updates in the same bucket fold together and out-of-order updates keep latest last" do
      w =
        Window.new(10_000, 1_000)
        |> Window.add(1_100, 20)
        |> Window.add(1_900, 5)
        |> Window.add(1_500, 30)

      s = Window.summary(w, 2_000)
      assert s.count == 3
      assert s.sum == 55
      assert s.min == 5
      assert s.max == 30
      assert s.last == 5

      # Late update expired relative to max_ts is ignored
      w2 = Window.add(w, 20_000, 99)
      w3 = Window.add(w2, 1_000, 500)
      s3 = Window.summary(w3, 20_000)
      assert s3.count == 1
      assert s3.sum == 99
      assert s3.last == 99
    end

    test "empty window summary has nil min, max, last and 0.0 rate_per_min" do
      w = Window.new(60_000, 1_000)
      s = Window.summary(w, 0)
      assert s == %Summary{count: 0, sum: 0, min: nil, max: nil, last: nil, rate_per_min: 0.0}
    end

    test "validates window dimensions and arguments" do
      assert_raise Error, fn -> Window.new(0, 1_000) end
      assert_raise Error, fn -> Window.new(60_000, 0) end
      assert_raise Error, fn -> Window.new(60_000, 7_000) end
      assert_raise Error, fn -> Window.new(3_601_000, 1_000) end

      w = Window.new(60_000, 1_000)
      bad_ts = :erlang.binary_to_term(:erlang.term_to_binary(:bad_ts))
      bad_val = :erlang.binary_to_term(:erlang.term_to_binary("12"))
      bad_now = :erlang.binary_to_term(:erlang.term_to_binary(:bad_now))
      assert_raise Error, fn -> Window.add(w, bad_ts, 1) end
      assert_raise Error, fn -> Window.add(w, 1_000, bad_val) end
      assert_raise Error, fn -> Window.summary(w, bad_now) end
    end

    test "Frame.to_map/1 produces string keys and plain values" do
      w = Window.new(60_000, 1_000) |> Window.add(1_000, 42.5)
      s = Window.summary(w, 1_000)
      frame = %Frame{seq: 7, at: 1_000, changes: %{"metric.a" => s}}

      assert Frame.to_map(frame) == %{
               "seq" => 7,
               "at" => 1_000,
               "changes" => %{
                 "metric.a" => %{
                   "count" => 1,
                   "sum" => 42.5,
                   "min" => 42.5,
                   "max" => 42.5,
                   "last" => 42.5,
                   "rate_per_min" => 1.0
                 }
               }
             }
    end
  end
end

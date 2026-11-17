defmodule Trysac.LiveviewRealtimeDashboard.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trysac.LiveviewRealtimeDashboard.Window

  property "Window.summary matches direct filtering of non-late samples within the active window" do
    check all(
            samples <-
              list_of(
                tuple({integer(0..120_000), integer(-1_000..1_000)}),
                min_length: 1,
                max_length: 60
              ),
            now_ms <- integer(0..130_000)
          ) do
      # Sort samples by timestamp so none are rejected as late during insertion
      sorted_samples = Enum.sort_by(samples, &elem(&1, 0))
      window_ms = 60_000
      bucket_ms = 1_000

      w =
        Enum.reduce(sorted_samples, Window.new(window_ms, bucket_ms), fn {ts, val}, acc ->
          Window.add(acc, ts, val)
        end)

      max_ts = sorted_samples |> List.last() |> elem(0)
      eval_now = max(now_ms, max_ts)

      summary = Window.summary(w, eval_now)

      active_values =
        for {ts, val} <- sorted_samples,
            Window.bucket_start(ts, bucket_ms) + window_ms > eval_now do
          val
        end

      assert summary.count == length(active_values)
      assert summary.sum == Enum.sum(active_values)

      if active_values == [] do
        assert summary.min == nil
        assert summary.max == nil
      else
        assert summary.min == Enum.min(active_values)
        assert summary.max == Enum.max(active_values)
      end
    end
  end
end

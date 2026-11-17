defmodule Trysac.LiveviewRealtimeDashboard.HubTest do
  use ExUnit.Case, async: true

  alias Trysac.LiveviewRealtimeDashboard.Error
  alias Trysac.LiveviewRealtimeDashboard.Frame
  alias Trysac.LiveviewRealtimeDashboard.Hub

  describe "acceptance criteria and core hub flows" do
    test "acceptance 2: 10_000 updates spread over 50 series with 3 subscribers to '*' and single flush" do
      {:ok, hub} = Hub.start_link(auto_tick: false)

      parent = self()

      subscribers =
        for i <- 1..3 do
          pid =
            spawn_link(fn ->
              receive do
                {:dashboard_frame, ref, frame} ->
                  send(parent, {:sub_received, i, ref, frame})
              end
            end)

          {:ok, ref} = Hub.subscribe(hub, "*", pid)
          {i, pid, ref}
        end

      for u <- 0..9_999 do
        series_idx = rem(u, 50) + 1
        series = "series.s_#{series_idx}"
        Hub.publish(hub, series, 1, 500 + rem(u, 500))
      end

      :ok = Hub.flush(hub, 1_000)

      for {i, _pid, expected_ref} <- subscribers do
        assert_receive {:sub_received, ^i, ^expected_ref, %Frame{} = frame}
        assert frame.seq == 1
        assert frame.at == 1_000
        assert map_size(frame.changes) == 50

        total_count =
          frame.changes
          |> Map.values()
          |> Enum.map(& &1.count)
          |> Enum.sum()

        assert total_count == 10_000
      end

      refute_receive {:sub_received, _, _, _}, 0
    end

    test "acceptance 3: throughput of 10_000 updates over a simulated minute with 600 flushes" do
      {:ok, hub} = Hub.start_link(auto_tick: false, window_ms: 60_000, bucket_ms: 1_000)
      {:ok, ref} = Hub.subscribe(hub, "*")

      # Distribute 10_000 updates across 600 intervals of 100ms (timestamps 0..59_999)
      # 400 intervals get 17 updates (6_800), 200 intervals get 16 updates (3_200) -> 10_000 total.
      frames =
        Enum.reduce(0..599, [], fn tick_idx, acc ->
          now_ms = tick_idx * 100
          updates_in_tick = if tick_idx < 400, do: 17, else: 16

          for j <- 1..updates_in_tick do
            ts = now_ms + rem(j, 100)
            Hub.publish(hub, "throughput.metric", 1, ts)
          end

          flush_at = now_ms + 99
          :ok = Hub.flush(hub, flush_at)

          receive do
            {:dashboard_frame, ^ref, %Frame{} = frame} ->
              :ok = Hub.ack(hub, ref, frame.seq)
              [frame | acc]
          after
            0 -> acc
          end
        end)
        |> Enum.reverse()

      assert length(frames) <= 600
      assert length(frames) == 600

      seqs = Enum.map(frames, & &1.seq)
      assert seqs == Enum.to_list(1..length(frames))

      last_frame = List.last(frames)
      final_summary = Map.fetch!(last_frame.changes, "throughput.metric")
      assert final_summary.count == 10_000
      assert final_summary.rate_per_min == 10_000.0
    end

    test "acceptance 4: flow control caps unacknowledged frames at max_inflight 3 and coalesces pending series" do
      events_agent = start_supervised!({Agent, fn -> [] end})

      {:ok, hub} =
        Hub.start_link(
          auto_tick: false,
          max_inflight: 3,
          on_event: fn ev -> Agent.update(events_agent, &[ev | &1]) end
        )

      {:ok, ref} = Hub.subscribe(hub, "*")

      # Tick 1..3: subscriber receives 3 frames without calling ack
      for tick <- 1..3 do
        Hub.publish(hub, "m.s1", tick, tick * 100)
        :ok = Hub.flush(hub, tick * 100)
        assert_receive {:dashboard_frame, ^ref, %Frame{seq: ^tick}}
      end

      # Tick 4..6: subscriber does not ack; publish across 4 distinct series
      for tick <- 4..6 do
        for s_idx <- 1..4 do
          Hub.publish(hub, "m.s#{s_idx}", tick * 10, tick * 100)
        end

        :ok = Hub.flush(hub, tick * 100)
        refute_receive {:dashboard_frame, ^ref, _}, 0

        stats = Hub.stats(hub)
        assert stats.pending_series[ref] <= stats.series
        assert stats.pending_series[ref] == 4
      end

      # Now ack seq 3; next flush sends one frame holding every series changed in the meantime
      :ok = Hub.ack(hub, ref, 3)
      :ok = Hub.flush(hub, 700)

      assert_receive {:dashboard_frame, ^ref, %Frame{seq: 4, at: 700, changes: changes}}
      assert Map.keys(changes) |> Enum.sort() == ["m.s1", "m.s2", "m.s3", "m.s4"]
      assert Hub.stats(hub).pending_series[ref] == 0

      events = Agent.get(events_agent, &Enum.reverse/1)
      assert Enum.any?(events, &(&1 == %{type: :frame_held, subscriber: ref}))
      assert Enum.any?(events, &(&1 == %{type: :frame_sent, subscriber: ref}))
    end

    test "acceptance 5: subscription patterns and subscriber process exit cleanup" do
      events_agent = start_supervised!({Agent, fn -> [] end})

      {:ok, hub} =
        Hub.start_link(
          auto_tick: false,
          on_event: fn ev -> Agent.update(events_agent, &[ev | &1]) end
        )

      {:ok, prefix_ref} = Hub.subscribe(hub, "cpu.*")
      {:ok, exact_ref} = Hub.subscribe(hub, "cpu.host1")

      temp_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, temp_ref} = Hub.subscribe(hub, "*", temp_pid)
      assert Hub.stats(hub).subscribers == 3

      # Two series under one prefix pattern plus one unrelated series
      Hub.publish(hub, "cpu.host1", 40, 1_000)
      Hub.publish(hub, "cpu.host2", 60, 1_000)
      Hub.publish(hub, "mem.host1", 80, 1_000)

      :ok = Hub.flush(hub, 1_000)

      assert_receive {:dashboard_frame, ^prefix_ref, %Frame{changes: prefix_changes}}
      assert Map.keys(prefix_changes) |> Enum.sort() == ["cpu.host1", "cpu.host2"]
      refute Map.has_key?(prefix_changes, "mem.host1")

      assert_receive {:dashboard_frame, ^exact_ref, %Frame{changes: exact_changes}}
      assert Map.keys(exact_changes) == ["cpu.host1"]

      # Stop the temporary subscriber process and verify monitor cleanup
      mon = Process.monitor(temp_pid)
      send(temp_pid, :stop)
      assert_receive {:DOWN, ^mon, :process, ^temp_pid, :normal}

      # Sync call to hub ensures the hub has processed its own :DOWN message
      assert Hub.stats(hub).subscribers == 2

      events = Agent.get(events_agent, & &1)
      assert Enum.any?(events, &(&1 == %{type: :subscriber_down, subscriber: temp_ref}))
    end

    test "acceptance 6: late update at 1_000 after 70_000 with window_ms 60_000 is dropped and snapshot returns all series" do
      events_agent = start_supervised!({Agent, fn -> [] end})

      {:ok, hub} =
        Hub.start_link(
          auto_tick: false,
          window_ms: 60_000,
          bucket_ms: 1_000,
          on_event: fn ev -> Agent.update(events_agent, &[ev | &1]) end
        )

      Hub.publish(hub, "cpu.host1", 50, 70_000)
      Hub.publish(hub, "cpu.host1", 10, 1_000)
      Hub.publish(hub, "mem.host1", 200, 70_000)

      stats = Hub.stats(hub)
      assert stats.late == 1
      assert stats.series == 2

      snap = Hub.snapshot(hub, 70_500)
      assert Map.keys(snap) |> Enum.sort() == ["cpu.host1", "mem.host1"]
      assert snap["cpu.host1"].count == 1
      assert snap["cpu.host1"].sum == 50
      assert snap["mem.host1"].count == 1
      assert snap["mem.host1"].sum == 200

      events = Agent.get(events_agent, & &1)
      assert Enum.any?(events, &(&1 == %{type: :late_update, subscriber: nil}))
    end

    test "acceptance 7: errors carry specified codes and truncate long inputs" do
      {:ok, hub} = Hub.start_link(auto_tick: false)

      # "CPU host" -> :invalid_series
      err1 =
        assert_raise Error, fn ->
          Hub.publish(hub, "CPU host", 1, 1_000)
        end

      assert err1.code == :invalid_series

      # 129 bytes -> :invalid_series
      series_129 = String.duplicate("a", 129)

      err2 =
        assert_raise Error, fn ->
          Hub.publish(hub, series_129, 1, 1_000)
        end

      assert err2.code == :invalid_series

      # Long input message truncation <= 200 chars of input
      series_500 = String.duplicate("x", 500)

      err_long =
        assert_raise Error, fn ->
          Hub.publish(hub, series_500, 1, 1_000)
        end

      assert err_long.code == :invalid_series
      assert String.length(err_long.message) < 260

      # value "12" -> :invalid_value
      bad_val = :erlang.binary_to_term(:erlang.term_to_binary("12"))

      err3 =
        assert_raise Error, fn ->
          Hub.publish(hub, "cpu.host1", bad_val, 1_000)
        end

      assert err3.code == :invalid_value

      # series 1_001 with max_series 1_000 -> :series_limit
      for i <- 1..1_000 do
        assert :ok = Hub.publish_sync(hub, "series.n_#{i}", i, 1_000)
      end

      assert {:error, %Error{code: :series_limit}} =
               Hub.publish_sync(hub, "series.n_1001", 1, 1_000)

      # Cast path also enforces max_series without crashing the hub
      :ok = Hub.publish(hub, "series.n_1001", 1, 1_000)
      assert Hub.stats(hub).series == 1_000

      # subscriber 1_001 with max_subscribers 1_000 -> :subscriber_limit
      for _idx <- 1..1_000 do
        assert {:ok, _ref} = Hub.subscribe(hub, "*")
      end

      assert {:error, %Error{code: :subscriber_limit}} = Hub.subscribe(hub, "*")

      # tick_ms 0 -> :invalid_option
      err4 =
        assert_raise Error, fn ->
          Hub.start_link(tick_ms: 0)
        end

      assert err4.code == :invalid_option

      # ack with an unknown ref -> :unknown_subscription
      unknown_ref = make_ref()
      assert {:error, %Error{code: :unknown_subscription}} = Hub.ack(hub, unknown_ref, 1)
      assert {:error, %Error{code: :unknown_subscription}} = Hub.unsubscribe(hub, unknown_ref)
    end
  end

  describe "edge cases and options" do
    test "flush with no changes sends nothing" do
      {:ok, hub} = Hub.start_link(auto_tick: false)
      {:ok, ref} = Hub.subscribe(hub, "*")

      :ok = Hub.flush(hub, 1_000)
      refute_receive {:dashboard_frame, ^ref, _}, 0

      Hub.publish(hub, "cpu.host1", 10, 1_000)
      :ok = Hub.flush(hub, 1_000)
      assert_receive {:dashboard_frame, ^ref, %Frame{seq: 1}}

      # Subsequent flush with no new updates sends nothing
      :ok = Hub.flush(hub, 2_000)
      refute_receive {:dashboard_frame, ^ref, _}, 0
    end

    test "re-subscribing the same pid twice produces two independent refs and sequences" do
      {:ok, hub} = Hub.start_link(auto_tick: false)
      {:ok, ref1} = Hub.subscribe(hub, "cpu.*")
      {:ok, ref2} = Hub.subscribe(hub, "cpu.*")

      assert ref1 != ref2
      assert Hub.stats(hub).subscribers == 2

      Hub.publish(hub, "cpu.host1", 5, 1_000)
      :ok = Hub.flush(hub, 1_000)

      assert_receive {:dashboard_frame, ^ref1, %Frame{seq: 1}}
      assert_receive {:dashboard_frame, ^ref2, %Frame{seq: 1}}

      :ok = Hub.unsubscribe(hub, ref1)
      assert Hub.stats(hub).subscribers == 1
    end

    test "ack of an old seq has no effect" do
      {:ok, hub} = Hub.start_link(auto_tick: false, max_inflight: 2)
      {:ok, ref} = Hub.subscribe(hub, "*")

      Hub.publish(hub, "cpu.host1", 1, 100)
      :ok = Hub.flush(hub, 100)
      assert_receive {:dashboard_frame, ^ref, %Frame{seq: 1}}

      Hub.publish(hub, "cpu.host1", 2, 200)
      :ok = Hub.flush(hub, 200)
      assert_receive {:dashboard_frame, ^ref, %Frame{seq: 2}}

      # Ack seq 1, then ack seq 1 again (old seq)
      assert :ok = Hub.ack(hub, ref, 1)
      assert :ok = Hub.ack(hub, ref, 1)
      assert :ok = Hub.ack(hub, ref, 0)

      # Seq 2 is still inflight (1 inflight < max_inflight 2), so one more frame can be sent
      Hub.publish(hub, "cpu.host1", 3, 300)
      :ok = Hub.flush(hub, 300)
      assert_receive {:dashboard_frame, ^ref, %Frame{seq: 3}}

      # Now seq 2 and 3 are inflight (2 == max_inflight), acking old seq 1 does not free seq 2 or 3
      assert :ok = Hub.ack(hub, ref, 1)
      Hub.publish(hub, "cpu.host1", 4, 400)
      :ok = Hub.flush(hub, 400)
      refute_receive {:dashboard_frame, ^ref, _}, 0
    end

    test "injected clock and manual :tick message work deterministically" do
      clock_agent = start_supervised!({Agent, fn -> 5_000 end})
      clock_fn = fn -> Agent.get(clock_agent, & &1) end

      {:ok, hub} =
        Hub.start_link(
          name: :test_named_hub,
          auto_tick: false,
          clock: clock_fn
        )

      {:ok, ref} = Hub.subscribe(:test_named_hub, "*")
      :ok = Hub.publish(:test_named_hub, "disk.io", 42)
      send(hub, :tick)

      assert_receive {:dashboard_frame, ^ref, %Frame{seq: 1, at: 5_000}}

      snap = Hub.snapshot(:test_named_hub)
      assert snap["disk.io"].last == 42
    end

    test "auto_tick schedules periodic ticks and ignores unknown info messages" do
      {:ok, hub} = Hub.start_link(auto_tick: true, tick_ms: 10_000, name: nil)
      send(hub, :unrelated_message)
      send(hub, {:DOWN, make_ref(), :process, self(), :normal})
      send(hub, :tick)
      assert Hub.stats(hub).series == 0
    end

    test "adversarial series names, patterns, and option validation errors" do
      {:ok, hub} = Hub.start_link(auto_tick: false)

      # Adversarial neighbours for series regex ~r/^[a-z0-9_.:-]{1,128}$/
      for invalid_series <- [
            "",
            "cpu host",
            "cpu/host",
            "cpu$host",
            "cpu\nhost",
            "CPU",
            123
          ] do
        err = assert_raise Error, fn -> Hub.publish(hub, invalid_series, 1, 100) end
        assert err.code == :invalid_series
      end

      # Valid edge characters: digits, underscore, dot, colon, hyphen
      assert :ok = Hub.publish_sync(hub, "a0_.:-z9", 1.5, 100)

      # Pattern validation
      assert_raise Error, fn -> Hub.subscribe(hub, ".*") end
      assert_raise Error, fn -> Hub.subscribe(hub, "BAD.*") end
      bad_pattern = :erlang.binary_to_term(:erlang.term_to_binary(123))
      bad_pid = :erlang.binary_to_term(:erlang.term_to_binary(:not_a_pid))
      assert_raise Error, fn -> Hub.subscribe(hub, bad_pattern) end
      assert_raise Error, fn -> Hub.subscribe(hub, "*", bad_pid) end

      # Argument validation on unsubscribe, ack, flush, snapshot, publish
      bad_ref = :erlang.binary_to_term(:erlang.term_to_binary(:not_a_ref))
      bad_now = :erlang.binary_to_term(:erlang.term_to_binary(:bad_now))
      bad_ts = :erlang.binary_to_term(:erlang.term_to_binary(:bad_ts))
      assert_raise Error, fn -> Hub.unsubscribe(hub, bad_ref) end
      assert_raise Error, fn -> Hub.ack(hub, bad_ref, 1) end
      assert_raise Error, fn -> Hub.ack(hub, make_ref(), -1) end
      assert_raise Error, fn -> Hub.flush(hub, bad_now) end
      assert_raise Error, fn -> Hub.snapshot(hub, bad_now) end
      assert_raise Error, fn -> Hub.publish(hub, "cpu.host1", 1, bad_ts) end
      assert_raise Error, fn -> Hub.publish_sync(hub, "cpu.host1", 1, bad_ts) end

      # Start option validations
      bad_opts = :erlang.binary_to_term(:erlang.term_to_binary(:not_a_keyword_list))
      assert_raise Error, fn -> Hub.start_link(bad_opts) end
      assert_raise Error, fn -> Hub.start_link(unknown_opt: 1) end
      assert_raise Error, fn -> Hub.start_link(auto_tick: :yes) end
      assert_raise Error, fn -> Hub.start_link(max_series: 0) end
      assert_raise Error, fn -> Hub.start_link(max_subscribers: -1) end
      assert_raise Error, fn -> Hub.start_link(max_inflight: 0) end
      assert_raise Error, fn -> Hub.start_link(clock: :not_a_fn) end
      assert_raise Error, fn -> Hub.start_link(on_event: fn -> :bad_arity end) end
    end
  end
end

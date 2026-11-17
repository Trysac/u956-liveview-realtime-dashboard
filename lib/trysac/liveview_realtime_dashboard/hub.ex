defmodule Trysac.LiveviewRealtimeDashboard.Hub do
  @moduledoc """
  GenServer that ingests metric updates into rolling bucketed windows and broadcasts
  coalesced `%Frame{}` messages to pattern-matched subscribers on each tick.

  ## Flow control

  Each subscriber has its own sequence counter starting at `1` and a limit of
  `max_inflight` unacknowledged frames (default `3`). When a flush occurs:

    * If the subscriber has changed matching series and fewer than `max_inflight`
      unacknowledged frames, the hub sends `{:dashboard_frame, ref, %Frame{}}` to
      the subscriber PID and clears its pending set.
    * If the subscriber has reached `max_inflight`, changed series names remain in
      the subscriber's `pending` set (bounded by the number of series, never a queue
      of frames) until `ack/3` frees inflight capacity.
  """

  use GenServer

  alias Trysac.LiveviewRealtimeDashboard.Error
  alias Trysac.LiveviewRealtimeDashboard.Frame
  alias Trysac.LiveviewRealtimeDashboard.Summary
  alias Trysac.LiveviewRealtimeDashboard.Window

  @series_regex ~r/^[a-z0-9_.:-]{1,128}$/
  @max_series_bytes 128

  @type hub :: GenServer.server()
  @type pattern :: String.t()
  @type compiled_pattern :: :all | {:prefix, String.t()} | {:exact, String.t()}

  @type event :: %{
          type: :frame_sent | :frame_held | :late_update | :subscriber_down,
          subscriber: reference() | nil
        }

  @type stats :: %{
          series: non_neg_integer(),
          subscribers: non_neg_integer(),
          late: non_neg_integer(),
          pending_series: %{reference() => non_neg_integer()}
        }

  @type option ::
          {:name, GenServer.name()}
          | {:window_ms, pos_integer()}
          | {:bucket_ms, pos_integer()}
          | {:tick_ms, pos_integer()}
          | {:auto_tick, boolean()}
          | {:max_series, pos_integer()}
          | {:max_subscribers, pos_integer()}
          | {:max_inflight, pos_integer()}
          | {:clock, (-> integer())}
          | {:on_event, (event() -> any()) | nil}

  defp default_clock, do: System.monotonic_time(:millisecond)

  @doc """
  Starts a `Hub` GenServer linked to the current process.

  ## Options

    * `:name` - optional GenServer registration name.
    * `:window_ms` - rolling window duration in ms (default `60_000`).
    * `:bucket_ms` - bucket width in ms (default `1_000`).
    * `:tick_ms` - interval between automatic flushes in ms (default `100`).
    * `:auto_tick` - whether to schedule automatic periodic ticks (default `true`).
    * `:max_series` - maximum distinct series allowed (default `1_000`).
    * `:max_subscribers` - maximum active subscriptions allowed (default `1_000`).
    * `:max_inflight` - maximum unacknowledged frames per subscriber (default `3`).
    * `:clock` - 0-arity function returning current ms (default `&System.monotonic_time(:millisecond)`).
    * `:on_event` - optional 1-arity telemetry callback receiving `%{type: ..., subscriber: ref}`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if not Keyword.keyword?(opts) do
      raise Error.new(
              :invalid_option,
              "opts must be a keyword list, got: #{Error.preview(opts)}"
            )
    end

    config = parse_and_validate_opts!(opts)

    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, config)
      {:ok, name} -> GenServer.start_link(__MODULE__, config, name: name)
      :error -> GenServer.start_link(__MODULE__, config)
    end
  end

  @doc """
  Validates `series`, `value`, and `ts_ms` in the caller and casts the update to `hub`.

  Raises `Trysac.LiveviewRealtimeDashboard.Error` in the calling process if `series`
  does not match `~r/^[a-z0-9_.:-]{1,128}$/`, `value` is not an integer or float,
  or `ts_ms` is not an integer.
  """
  @spec publish(hub(), String.t(), number(), integer() | nil) :: :ok
  def publish(hub, series, value, ts_ms \\ nil) do
    validate_series!(series)
    validate_value!(value)

    if ts_ms != nil and not is_integer(ts_ms) do
      raise Error.new(
              :invalid_option,
              "ts_ms must be an integer, got: #{Error.preview(ts_ms)}"
            )
    end

    GenServer.cast(hub, {:publish, series, value, ts_ms})
  end

  @doc """
  Synchronously publishes a metric update and returns `:ok` or `{:error, %Error{}}`
  (for example when `:series_limit` is reached).

  Also validates `series`, `value`, and `ts_ms` in the caller, raising `%Error{}` on invalid input.
  """
  @spec publish_sync(hub(), String.t(), number(), integer() | nil) :: :ok | {:error, Error.t()}
  def publish_sync(hub, series, value, ts_ms \\ nil) do
    validate_series!(series)
    validate_value!(value)

    if ts_ms != nil and not is_integer(ts_ms) do
      raise Error.new(
              :invalid_option,
              "ts_ms must be an integer, got: #{Error.preview(ts_ms)}"
            )
    end

    GenServer.call(hub, {:publish_sync, series, value, ts_ms})
  end

  @doc """
  Subscribes `pid` (defaults to `self()`) to series matching `pattern`.

  Supported patterns:

    * `"*"` - matches every series.
    * `"<prefix>.*"` - matches any series starting with `"<prefix>."` where `<prefix>` is a valid series name.
    * `"<exact>"` - matches only the exact series name.

  Returns `{:ok, ref}` or `{:error, %Error{code: :subscriber_limit}}` (or raises `%Error{}`
  when the pattern or pid is invalid).
  """
  @spec subscribe(hub(), pattern(), pid()) :: {:ok, reference()} | {:error, Error.t()}
  def subscribe(hub, pattern, pid \\ self()) do
    if not is_pid(pid) do
      raise Error.new(
              :invalid_option,
              "subscriber pid must be a PID, got: #{Error.preview(pid)}"
            )
    end

    compiled = compile_pattern!(pattern)
    GenServer.call(hub, {:subscribe, pattern, compiled, pid})
  end

  @doc """
  Removes the subscription identified by `ref`.

  Returns `:ok` or `{:error, %Error{code: :unknown_subscription}}`.
  """
  @spec unsubscribe(hub(), reference()) :: :ok | {:error, Error.t()}
  def unsubscribe(hub, ref) do
    if not is_reference(ref) do
      raise Error.new(
              :unknown_subscription,
              "subscription ref must be a reference, got: #{Error.preview(ref)}"
            )
    end

    GenServer.call(hub, {:unsubscribe, ref})
  end

  @doc """
  Acknowledges all frames up to and including `seq` for subscription `ref`.

  Acknowledging an already-acknowledged or older `seq` is a no-op and returns `:ok`.
  Returns `{:error, %Error{code: :unknown_subscription}}` (or raises if called via `!`)
  when `ref` is unknown.
  """
  @spec ack(hub(), reference(), pos_integer()) :: :ok | {:error, Error.t()}
  def ack(hub, ref, seq) do
    if not is_reference(ref) do
      raise Error.new(
              :unknown_subscription,
              "subscription ref must be a reference, got: #{Error.preview(ref)}"
            )
    end

    if not is_integer(seq) or seq < 0 do
      raise Error.new(
              :invalid_option,
              "seq must be a non-negative integer, got: #{Error.preview(seq)}"
            )
    end

    GenServer.call(hub, {:ack, ref, seq})
  end

  @doc """
  Flushes pending series updates at `now_ms`, sending `{:dashboard_frame, ref, %Frame{}}`
  to each subscriber that has pending updates and fewer than `max_inflight` unacknowledged frames.
  """
  @spec flush(hub(), integer() | nil) :: :ok
  def flush(hub, now_ms \\ nil) do
    if now_ms != nil and not is_integer(now_ms) do
      raise Error.new(
              :invalid_option,
              "now_ms must be an integer, got: #{Error.preview(now_ms)}"
            )
    end

    GenServer.call(hub, {:flush, now_ms})
  end

  @doc """
  Returns a map of `%{series => Summary.t()}` for every registered series evaluated at `now_ms`.
  """
  @spec snapshot(hub(), integer() | nil) :: %{String.t() => Summary.t()}
  def snapshot(hub, now_ms \\ nil) do
    if now_ms != nil and not is_integer(now_ms) do
      raise Error.new(
              :invalid_option,
              "now_ms must be an integer, got: #{Error.preview(now_ms)}"
            )
    end

    GenServer.call(hub, {:snapshot, now_ms})
  end

  @doc """
  Returns current hub statistics:

    * `:series` - number of tracked metric series.
    * `:subscribers` - number of active subscriptions.
    * `:late` - count of dropped late updates.
    * `:pending_series` - map of `%{ref => count_of_pending_series}` for every active subscriber.
  """
  @spec stats(hub()) :: stats()
  def stats(hub) do
    GenServer.call(hub, :stats)
  end

  @doc """
  Validates a series name against `~r/^[a-z0-9_.:-]{1,128}$/`.
  Raises `Trysac.LiveviewRealtimeDashboard.Error` with code `:invalid_series` if invalid.
  """
  @spec validate_series!(term()) :: :ok
  def validate_series!(series) do
    if is_binary(series) and byte_size(series) >= 1 and byte_size(series) <= @max_series_bytes and
         Regex.match?(@series_regex, series) do
      :ok
    else
      raise Error.new(
              :invalid_series,
              "invalid series name #{Error.preview(series)}: must match ^[a-z0-9_.:-]{1,128}$"
            )
    end
  end

  @doc """
  Validates that `value` is an integer or float.
  Raises `Trysac.LiveviewRealtimeDashboard.Error` with code `:invalid_value` if invalid.
  """
  @spec validate_value!(term()) :: :ok
  def validate_value!(value) do
    if is_number(value) do
      :ok
    else
      raise Error.new(
              :invalid_value,
              "invalid metric value #{Error.preview(value)}: expected integer or float"
            )
    end
  end

  @doc """
  Compiles and validates a subscription pattern.
  """
  @spec compile_pattern!(term()) :: compiled_pattern()
  def compile_pattern!("*"), do: :all

  def compile_pattern!(pattern) when is_binary(pattern) do
    if String.ends_with?(pattern, ".*") do
      prefix_base = String.slice(pattern, 0, byte_size(pattern) - 2)
      validate_series!(prefix_base)
      {:prefix, prefix_base <> "."}
    else
      validate_series!(pattern)
      {:exact, pattern}
    end
  end

  def compile_pattern!(pattern) do
    raise Error.new(
            :invalid_series,
            "invalid subscription pattern #{Error.preview(pattern)}"
          )
  end

  @doc """
  Checks whether a compiled pattern matches `series`.
  """
  @spec pattern_matches?(compiled_pattern(), String.t()) :: boolean()
  def pattern_matches?(:all, _series), do: true
  def pattern_matches?({:exact, exact}, series), do: exact == series

  def pattern_matches?({:prefix, prefix_dot}, series) do
    String.starts_with?(series, prefix_dot)
  end

  # GenServer callbacks

  @impl true
  def init(config) do
    state = %{
      window_ms: config.window_ms,
      bucket_ms: config.bucket_ms,
      tick_ms: config.tick_ms,
      auto_tick: config.auto_tick,
      max_series: config.max_series,
      max_subscribers: config.max_subscribers,
      max_inflight: config.max_inflight,
      clock: config.clock,
      on_event: config.on_event,
      windows: %{},
      subscribers: %{},
      monitors: %{},
      max_ts: nil,
      late: 0
    }

    if config.auto_tick do
      schedule_tick(config.tick_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:publish, series, value, ts_ms}, state) do
    {_reply, new_state} = do_publish(state, series, value, ts_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:publish_sync, series, value, ts_ms}, _from, state) do
    {reply, new_state} = do_publish(state, series, value, ts_ms)
    {:reply, reply, new_state}
  end

  def handle_call({:subscribe, pattern, compiled, pid}, _from, state) do
    if map_size(state.subscribers) >= state.max_subscribers do
      err =
        Error.new(
          :subscriber_limit,
          "max_subscribers limit (#{state.max_subscribers}) reached"
        )

      {:reply, {:error, err}, state}
    else
      ref = make_ref()
      mon_ref = Process.monitor(pid)

      sub = %{
        ref: ref,
        pid: pid,
        mon_ref: mon_ref,
        pattern: pattern,
        compiled: compiled,
        next_seq: 1,
        inflight: MapSet.new(),
        pending: MapSet.new()
      }

      new_state = %{
        state
        | subscribers: Map.put(state.subscribers, ref, sub),
          monitors: Map.put(state.monitors, mon_ref, ref)
      }

      {:reply, {:ok, ref}, new_state}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    case Map.pop(state.subscribers, ref) do
      {nil, _subs} ->
        err =
          Error.new(
            :unknown_subscription,
            "unknown subscription ref: #{Error.preview(ref)}"
          )

        {:reply, {:error, err}, state}

      {sub, remaining_subs} ->
        Process.demonitor(sub.mon_ref, [:flush])
        remaining_monitors = Map.delete(state.monitors, sub.mon_ref)

        {:reply, :ok, %{state | subscribers: remaining_subs, monitors: remaining_monitors}}
    end
  end

  def handle_call({:ack, ref, seq}, _from, state) do
    case Map.fetch(state.subscribers, ref) do
      :error ->
        err =
          Error.new(
            :unknown_subscription,
            "unknown subscription ref: #{Error.preview(ref)}"
          )

        {:reply, {:error, err}, state}

      {:ok, sub} ->
        updated_inflight =
          sub.inflight
          |> Enum.reject(&(&1 <= seq))
          |> MapSet.new()

        updated_sub = %{sub | inflight: updated_inflight}
        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, ref, updated_sub)}}
    end
  end

  def handle_call({:flush, now_ms}, _from, state) do
    effective_now = now_ms || state.clock.()
    new_state = do_flush(state, effective_now)
    {:reply, :ok, new_state}
  end

  def handle_call({:snapshot, now_ms}, _from, state) do
    effective_now = now_ms || state.clock.()

    snap =
      Map.new(state.windows, fn {series, window} ->
        {series, Window.summary(window, effective_now)}
      end)

    {:reply, snap, state}
  end

  def handle_call(:stats, _from, state) do
    pending_series =
      Map.new(state.subscribers, fn {ref, sub} ->
        {ref, MapSet.size(sub.pending)}
      end)

    reply = %{
      series: map_size(state.windows),
      subscribers: map_size(state.subscribers),
      late: state.late,
      pending_series: pending_series
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now_ms = state.clock.()
    new_state = do_flush(state, now_ms)

    if state.auto_tick do
      schedule_tick(state.tick_ms)
    end

    {:noreply, new_state}
  end

  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, mon_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {sub_ref, remaining_monitors} ->
        remaining_subs = Map.delete(state.subscribers, sub_ref)
        emit_event(state.on_event, %{type: :subscriber_down, subscriber: sub_ref})
        {:noreply, %{state | subscribers: remaining_subs, monitors: remaining_monitors}}
    end
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  # Internal helpers

  defp do_publish(state, series, value, ts_ms) do
    effective_ts = ts_ms || state.clock.()

    if over_series_limit?(state, series) do
      err =
        Error.new(
          :series_limit,
          "max_series limit (#{state.max_series}) reached"
        )

      {{:error, err}, state}
    else
      publish_valid_metric(state, series, value, effective_ts)
    end
  end

  defp over_series_limit?(state, series) do
    not Map.has_key?(state.windows, series) and map_size(state.windows) >= state.max_series
  end

  defp publish_valid_metric(state, series, value, effective_ts) do
    new_max_ts = update_max_ts(state.max_ts, effective_ts)
    b_start = Window.bucket_start(effective_ts, state.bucket_ms)

    if b_start + state.window_ms <= new_max_ts do
      emit_event(state.on_event, %{type: :late_update, subscriber: nil})
      {:ok, %{state | max_ts: new_max_ts, late: state.late + 1}}
    else
      accept_metric(state, series, value, effective_ts, new_max_ts)
    end
  end

  defp accept_metric(state, series, value, effective_ts, new_max_ts) do
    updated_windows = update_series_window(state, series, effective_ts, value)
    updated_subs = notify_matching_subscribers(state.subscribers, series)

    {:ok,
     %{
       state
       | windows: updated_windows,
         subscribers: updated_subs,
         max_ts: new_max_ts
     }}
  end

  defp update_series_window(state, series, effective_ts, value) do
    window =
      case Map.fetch(state.windows, series) do
        {:ok, existing} -> existing
        :error -> Window.new(state.window_ms, state.bucket_ms)
      end

    updated_window = Window.add(window, effective_ts, value)
    Map.put(state.windows, series, updated_window)
  end

  defp notify_matching_subscribers(subscribers, series) do
    Map.new(subscribers, fn {ref, sub} ->
      {ref, maybe_mark_pending(sub, series)}
    end)
  end

  defp maybe_mark_pending(sub, series) do
    if pattern_matches?(sub.compiled, series) do
      %{sub | pending: MapSet.put(sub.pending, series)}
    else
      sub
    end
  end

  defp update_max_ts(nil, ts), do: ts
  defp update_max_ts(prev, ts), do: max(prev, ts)

  defp do_flush(state, now_ms) do
    new_max_ts = update_max_ts(state.max_ts, now_ms)

    {updated_subs, _cache} =
      Enum.reduce(state.subscribers, {%{}, %{}}, fn {ref, sub}, {subs_acc, summary_cache} ->
        flush_subscriber(sub, ref, state, now_ms, subs_acc, summary_cache)
      end)

    %{state | subscribers: updated_subs, max_ts: new_max_ts}
  end

  defp flush_subscriber(sub, ref, state, now_ms, subs_acc, summary_cache) do
    cond do
      MapSet.size(sub.pending) == 0 ->
        {Map.put(subs_acc, ref, sub), summary_cache}

      MapSet.size(sub.inflight) >= state.max_inflight ->
        emit_event(state.on_event, %{type: :frame_held, subscriber: ref})
        {Map.put(subs_acc, ref, sub), summary_cache}

      true ->
        deliver_flush_frame(sub, ref, state, now_ms, subs_acc, summary_cache)
    end
  end

  defp deliver_flush_frame(sub, ref, state, now_ms, subs_acc, summary_cache) do
    {changes, next_cache} =
      build_changes(sub.pending, state.windows, now_ms, summary_cache)

    seq = sub.next_seq
    frame = %Frame{seq: seq, at: now_ms, changes: changes}
    send(sub.pid, {:dashboard_frame, ref, frame})
    emit_event(state.on_event, %{type: :frame_sent, subscriber: ref})

    updated_sub = %{
      sub
      | next_seq: seq + 1,
        inflight: MapSet.put(sub.inflight, seq),
        pending: MapSet.new()
    }

    {Map.put(subs_acc, ref, updated_sub), next_cache}
  end

  defp build_changes(pending_set, windows, now_ms, summary_cache) do
    Enum.reduce(pending_set, {%{}, summary_cache}, fn series, {changes_acc, cache_acc} ->
      case Map.fetch(cache_acc, series) do
        {:ok, summary} ->
          {Map.put(changes_acc, series, summary), cache_acc}

        :error ->
          window = Map.fetch!(windows, series)
          summary = Window.summary(window, now_ms)
          {Map.put(changes_acc, series, summary), Map.put(cache_acc, series, summary)}
      end
    end)
  end

  defp schedule_tick(tick_ms) do
    _timer = Process.send_after(self(), :tick, tick_ms)
    :ok
  end

  defp emit_event(nil, _event), do: :ok

  defp emit_event(callback, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end

  defp parse_and_validate_opts!(opts) do
    allowed_keys = [
      :name,
      :window_ms,
      :bucket_ms,
      :tick_ms,
      :auto_tick,
      :max_series,
      :max_subscribers,
      :max_inflight,
      :clock,
      :on_event
    ]

    unknown = Keyword.keys(opts) -- allowed_keys

    if unknown != [] do
      raise Error.new(
              :invalid_option,
              "unknown options: #{Error.preview(unknown)}"
            )
    end

    window_ms = Keyword.get(opts, :window_ms, 60_000)
    bucket_ms = Keyword.get(opts, :bucket_ms, 1_000)
    tick_ms = Keyword.get(opts, :tick_ms, 100)
    auto_tick = Keyword.get(opts, :auto_tick, true)
    max_series = Keyword.get(opts, :max_series, 1_000)
    max_subscribers = Keyword.get(opts, :max_subscribers, 1_000)
    max_inflight = Keyword.get(opts, :max_inflight, 3)
    clock = Keyword.get(opts, :clock, &default_clock/0)
    on_event = Keyword.get(opts, :on_event, nil)

    Window.validate_dimensions!(window_ms, bucket_ms)
    validate_pos_int!(:tick_ms, tick_ms)
    validate_boolean!(:auto_tick, auto_tick)
    validate_pos_int!(:max_series, max_series)
    validate_pos_int!(:max_subscribers, max_subscribers)
    validate_pos_int!(:max_inflight, max_inflight)
    validate_clock!(clock)
    validate_on_event!(on_event)

    %{
      window_ms: window_ms,
      bucket_ms: bucket_ms,
      tick_ms: tick_ms,
      auto_tick: auto_tick,
      max_series: max_series,
      max_subscribers: max_subscribers,
      max_inflight: max_inflight,
      clock: clock,
      on_event: on_event
    }
  end

  defp validate_pos_int!(key, val) do
    if not is_integer(val) or val <= 0 do
      raise Error.new(
              :invalid_option,
              "#{key} must be a positive integer, got: #{Error.preview(val)}"
            )
    end
  end

  defp validate_boolean!(key, val) do
    if not is_boolean(val) do
      raise Error.new(
              :invalid_option,
              "#{key} must be a boolean, got: #{Error.preview(val)}"
            )
    end
  end

  defp validate_clock!(clock) do
    if not is_function(clock, 0) do
      raise Error.new(
              :invalid_option,
              "clock must be a 0-arity function, got: #{Error.preview(clock)}"
            )
    end
  end

  defp validate_on_event!(nil), do: :ok

  defp validate_on_event!(on_event) do
    if not is_function(on_event, 1) do
      raise Error.new(
              :invalid_option,
              "on_event must be a 1-arity function or nil, got: #{Error.preview(on_event)}"
            )
    end
  end
end

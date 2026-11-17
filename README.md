# trysac_liveview_realtime_dashboard

Real-time dashboard hub that folds metric updates into rolling bucketed windows and sends each subscriber one coalesced frame per tick, with acknowledgement-based flow control.

## Why not just use Phoenix PubSub?

A live dashboard that pushes every metric update straight to each viewer floods browsers and server mailboxes once updates reach thousands per minute. A single slow viewer makes the server's memory grow without limit. `Trysac.LiveviewRealtimeDashboard` aggregates updates into rolling bucketed windows, sends each viewer at most one `%Frame{}` of changed series per tick, and holds back frames when a viewer has reached `max_inflight` unacknowledged frames.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [{:trysac_liveview_realtime_dashboard, "~> 0.1.0"}]
end
```

## Usage

```elixir
alias Trysac.LiveviewRealtimeDashboard.Hub

{:ok, hub} = Hub.start_link(auto_tick: false, window_ms: 60_000, bucket_ms: 1_000)
{:ok, ref} = Hub.subscribe(hub, "cpu.*")
:ok = Hub.publish(hub, "cpu.host1", 42.5, 1_000)
:ok = Hub.flush(hub, 1_000)
receive do
  {:dashboard_frame, ^ref, frame} -> Hub.ack(hub, ref, frame.seq)
end
```

## API Summary

- `Window.new(window_ms, bucket_ms)`: Creates a rolling window.
- `Window.add(window, ts_ms, value)`: Adds data points.
- `Window.summary(window, now_ms)`: Returns `%Summary{count, sum, min, max, last, rate_per_min}`.
- `Hub.start_link(opts)`: Starts the hub process.
- `Hub.publish(hub, series, value, ts_ms)`: Publishes a metric update.
- `Hub.subscribe(hub, pattern, pid)`: Subscribes to metric patterns (`"*"` or `"prefix.*"`).
- `Hub.flush(hub, now_ms)`: Triggers a manual frame push.
- `Hub.ack(hub, ref, seq)`: Acknowledges a specific frame to release flow control.

Errors (raised as `Trysac.LiveviewRealtimeDashboard.Error`): `:invalid_series`, `:invalid_value`, `:invalid_option`, `:series_limit`, `:subscriber_limit`, `:unknown_subscription`.

## Security

See [docs/SECURITY.md](docs/SECURITY.md).

# Architecture

## Overview

`Trysac.LiveviewRealtimeDashboard` is structured into pure window aggregation structs and an OTP `GenServer` hub:

1. **`Trysac.LiveviewRealtimeDashboard.Window`**: Pure functional rolling window dividing `window_ms` into buckets of `bucket_ms` (at most 3,600 buckets). Each bucket maintains `count`, `sum`, `min`, and `max`. Expired buckets (`bucket_start + window_ms <= max_ts`) are pruned on write, and `Window.summary/2` folds active buckets (`bucket_start + window_ms > now_ms`) in O(active_buckets).
2. **`Trysac.LiveviewRealtimeDashboard.Summary`**: Immutable aggregate (`count`, `sum`, `min`, `max`, `last`, `rate_per_min`).
3. **`Trysac.LiveviewRealtimeDashboard.Frame`**: Per-subscriber coalesced tick payload (`seq`, `at`, `changes`) with `Frame.to_map/1` for JSON serialization.
4. **`Trysac.LiveviewRealtimeDashboard.Hub`**: `GenServer` maintaining the map of series windows, subscriber monitors, per-subscriber pending series sets, and inflight frame sets.
5. **`Trysac.LiveviewRealtimeDashboard.Error`**: Library exception with `:code` and `:message` (truncating caller input previews to at most 200 characters).

## Bounded Memory for Slow Subscribers

When a subscriber has `max_inflight` unacknowledged frames, the hub does not buffer outgoing `%Frame{}` structs. Instead, each subscriber holds a `pending` `MapSet` of changed series names. No matter how many updates arrive while a subscriber is stalled, its `pending` set never exceeds the number of tracked series (`max_series`). Once `Hub.ack/3` frees inflight capacity, the next flush computes fresh `%Summary{}` values for all series in `pending` and delivers them in a single coalesced frame.

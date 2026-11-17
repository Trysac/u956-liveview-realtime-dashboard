# Coalesce slow-subscriber updates as a pending series set rather than a frame queue

Status: accepted (generated, pending human review)

## Context

Under high metric throughput (10,000+ updates per minute), pushing individual updates or queuing unacknowledged frames per subscriber causes unbounded mailbox or heap growth when a client connection stalls.

## Decision

Maintain rolling bucketed aggregates in pure `Window` structs and track unshipped changes per subscriber as a `MapSet` of dirty series names alongside an inflight sequence set capped at `max_inflight`. On each flush tick, compute each dirty series summary once and emit a single `%Frame{}` only to subscribers below `max_inflight`.

## Consequences

Memory per subscriber is strictly bounded by `max_series` and `max_inflight` regardless of update rate or client lag; recovering subscribers immediately receive the latest exact rolling window summaries in one coalesced frame.

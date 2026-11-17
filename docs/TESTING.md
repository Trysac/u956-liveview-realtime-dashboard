# Testing

## Testing Suite

Tests are located in `test/trysac/liveview_realtime_dashboard/` and cover:

- `HubTest.exs`: Core flows: 10,000 updates throughput, flow control (max_inflight), subscription patterns (`*`, `prefix.*`), process monitor cleanup, late update rejection, and error handling (input truncation and error codes).
- `PropertiesTest.exs`: Property-based tests verifying `Window.summary` logic invariants (matching direct filtering of samples).
- `TextPropertiesTest.exs`: Idempotence and normalization property tests for series text inputs.
- `TextTest.exs`: Unit tests for text normalization (trimming, lowercasing) and `BlankInputError` triggers.
- `WindowTest.exs`: Unit tests for rolling window logic, summary calculations (empty vs non-empty, rate calculations), and configuration validation.

## Strategy

All tests are deterministic: they rely on `auto_tick: false`, explicit `flush` timestamps, and no real-time sleeping. The suite uses `ExUnit.Case` with `async: true`. Property tests utilize `ExUnitProperties` for input generation. Failures are reproducible via the seed printed by `mix test` using `mix test --seed <n>`.

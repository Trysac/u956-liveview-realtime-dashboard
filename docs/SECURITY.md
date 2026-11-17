# Security notes

## Threat model

The library `trysac_liveview_realtime_dashboard` is a pure library without I/O side effects, operating on structured input.

### Defended

- **Hostile Inputs**: The library guards public entry points (`publish`, `subscribe`, `start_link`) by validating inputs against constraints (e.g., regex `~r/^[a-z0-9_.:-]{1,128}$/` for series names). Inputs exceeding 200 characters in error messages are truncated to prevent denial-of-service via memory allocation in error reporting.
- **Uncontrolled Subscriber Memory**: Subscribers with `max_inflight` frames pending do not queue multiple frames. The hub tracks a `MapSet` of `pending_series` names only, capping memory growth relative to `max_series`.
- **Process Leaks**: The hub monitors subscriber processes; exit of the subscriber process automatically triggers cleanup of subscriptions.

### Not defended

- **Caller Privilege**: The hub trusts the PID passed to `subscribe` and the caller of `publish`; it does not implement access control or authentication.
- **Resource Exhaustion (Memory)**: While per-subscriber memory is capped, the total number of series and subscribers is finite but configurable; misconfiguration (e.g., arbitrarily high limits) is the responsibility of the operator.

## Vulnerabilities

Report vulnerabilities via standard package management security channels; see `mix hex.audit` and `mix deps.audit`.

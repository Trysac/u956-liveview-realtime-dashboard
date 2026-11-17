# Architecture

## Purpose

The Hex package `trysac_liveview_realtime_dashboard` is a small, dependency-free Elixir library: Real-time dashboard hub that folds metric updates into rolling bucketed windows and sends each subscriber one coalesced frame per tick, with acknowledgement-based flow control

## Shape

```text
caller code --> Trysac.LiveviewRealtimeDashboard (lib/trysac/liveview_realtime_dashboard.ex)
                    |
                    +-- Trysac.LiveviewRealtimeDashboard.* (lib/trysac/liveview_realtime_dashboard/)
                          +-- modules of pure functions; no processes, no I/O, no global state
                          +-- @moduledoc false / @doc false helpers (private, optional)
```

- **Public API**: every module of `lib/` with a `@moduledoc` and its public functions and macros.
  Modules marked `@moduledoc false` and functions marked `@doc false` are private and may change
  without a major version.
- **Errors**: invalid input raises an exception of the library (such as `BlankInputError`,
  defined with `defexception`) documented in the function's `@doc`, or the function returns
  `{:ok, value} | {:error, reason}` when failure is an expected outcome. The library never prints,
  halts the VM, starts processes or changes application environment.
- **Side effects**: none. If a feature needs I/O, accept data or a small behaviour instead of
  opening files, and record the choice in an ADR.

## Quality contract

`scripts/check.exs` is the single definition of the gates; `fabrica.json` tells the factory and CI
how to run it. See [TESTING.md](TESTING.md).

## Decisions

Architecture decisions are recorded in [decisions/](decisions/) as numbered ADRs.

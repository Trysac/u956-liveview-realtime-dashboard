# liveview-realtime-dashboard

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/Trysac/u956-liveview-realtime-dashboard/actions/workflows/ci.yml/badge.svg)](https://github.com/Trysac/u956-liveview-realtime-dashboard/actions/workflows/ci.yml)

Real-time dashboard hub that folds metric updates into rolling bucketed windows and sends each subscriber one coalesced frame per tick, with acknowledgement-based flow control

## Problem

Describe in two or three sentences the concrete problem this utility solves, who hits it, and what
they do today without it. Replace this paragraph when the first real feature lands.

## Install

```elixir
# mix.exs
def deps do
  [{:trysac_liveview_realtime_dashboard, "~> 0.1"}]
end
```

Until it is published on Hex, point the dependency at a release tag:
`{:trysac_liveview_realtime_dashboard, git: "https://github.com/Trysac/u956-liveview-realtime-dashboard", tag: "v0.1.0"}`. Requires Elixir 1.20 or newer on
Erlang/OTP 29. No dependencies outside the Elixir standard library.

## Usage

```elixir
# normalize trims surrounding whitespace and lower-cases the text.
Trysac.LiveviewRealtimeDashboard.Text.normalize("  Hello World ")
#=> "hello world"

# Blank input is rejected explicitly instead of returning an empty string.
Trysac.LiveviewRealtimeDashboard.Text.normalize("   ")
#=> ** (Trysac.LiveviewRealtimeDashboard.BlankInputError) input is blank
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md) and [decisions](docs/decisions/)
- [Testing](docs/TESTING.md) and [security](docs/SECURITY.md)
- [Project record](docs/PROJECT.md) and [stack](docs/STACK.md)
- [Changelog](CHANGELOG.md) and [contributing guide](CONTRIBUTING.md)

## License

[MIT](LICENSE) (c) 2026 Miguel Gomez

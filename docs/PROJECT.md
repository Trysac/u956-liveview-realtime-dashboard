# Project record

## Objective

Real-time dashboard hub that folds metric updates into rolling bucketed windows and sends each subscriber one coalesced frame per tick, with acknowledgement-based flow control.

## Scope

- In-scope: `Window` aggregation structs, `Hub` GenServer flow control, `Frame` payload coalescing, `Text` normalization, and deterministic testing of throughput, flow control, and subscription pattern matching.
- Out-of-scope: Phoenix, LiveView, and PubSub integration, distributed node clusters, persistence of history, calculating percentiles, authentication, and CLI interfaces.

## Effort metrics

| Metric | Value |
|---|---|
| Tokens (input / output) | 3809476 / 35715 |
| Hours (human) | pending measurement |
| Cost (USD) | 1.1819 |

## Factory run u956 (measured from API usage)

| Date (UTC) | Phase | Model | Batch | Input | Output | Cache write | Cache read | Cost (USD) |
|---|---|---|---|---|---|---|---|---|
| 2026-11-17 | generation | google/gemini-4-argon | yes | 6628 | 21619 | 0 | 0 | 0.4589 |
| 2026-11-17 | fix-1 | google/gemini-3.8-flash | no | 192755 | 7276 | 0 | 1367404 | 0.2744 |
| 2026-11-17 | fix-2 | google/gemini-3.8-flash | no | 67096 | 2753 | 0 | 466685 | 0.0956 |
| 2026-11-17 | audit | google/gemini-3.8-flash | no | 208070 | 1593 | 0 | 1089106 | 0.2437 |
| 2026-11-17 | threat-model | google/gemini-3.8-flash | no | 103947 | 879 | 0 | 293241 | 0.1032 |
| 2026-11-17 | docs | google/gemini-3.1-flash-lite | no | 14544 | 1595 | 0 | 0 | 0.0060 |

Total: $1.1819. Prices: vertex line, as measured by its adapter. Providers serve the current version of each model id, so the date tells which version answered; versions, launch stages and price sources per line are in the factory's model register (docs/MODELS.md).

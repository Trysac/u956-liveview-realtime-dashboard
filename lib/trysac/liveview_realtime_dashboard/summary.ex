defmodule Trysac.LiveviewRealtimeDashboard.Summary do
  @moduledoc """
  Rolling window summary statistics for a metric series.

  Fields:

    * `:count` - total number of updates inside the active window.
    * `:sum` - sum of values inside the active window.
    * `:min` - minimum value inside the active window, or `nil` when `count == 0`.
    * `:max` - maximum value inside the active window, or `nil` when `count == 0`.
    * `:last` - value of the update with the greatest timestamp seen by the window (even if all active buckets expired), or `nil` if no updates were ever recorded.
    * `:rate_per_min` - `count * 60_000 / window_ms` as a float.
  """

  @enforce_keys [:count, :sum, :min, :max, :last, :rate_per_min]
  defstruct [:count, :sum, :min, :max, :last, :rate_per_min]

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          sum: number(),
          min: number() | nil,
          max: number() | nil,
          last: number() | nil,
          rate_per_min: float()
        }

  @doc """
  Converts a `%Summary{}` struct into a plain map with string keys suitable for JSON serialization.

  ## Examples

      iex> summary = %Trysac.LiveviewRealtimeDashboard.Summary{
      ...>   count: 2,
      ...>   sum: 15,
      ...>   min: 5,
      ...>   max: 10,
      ...>   last: 10,
      ...>   rate_per_min: 2.0
      ...> }
      iex> Trysac.LiveviewRealtimeDashboard.Summary.to_map(summary)
      %{
        "count" => 2,
        "sum" => 15,
        "min" => 5,
        "max" => 10,
        "last" => 10,
        "rate_per_min" => 2.0
      }

  """
  @spec to_map(t()) :: %{String.t() => number() | nil}
  def to_map(%__MODULE__{} = summary) do
    %{
      "count" => summary.count,
      "sum" => summary.sum,
      "min" => summary.min,
      "max" => summary.max,
      "last" => summary.last,
      "rate_per_min" => summary.rate_per_min
    }
  end
end

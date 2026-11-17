defmodule Trysac.LiveviewRealtimeDashboard.Frame do
  @moduledoc """
  Coalesced frame of changed series summaries delivered to a subscriber on a flush tick.

  Fields:

    * `:seq` - monotonically increasing sequence number per subscriber starting at `1`.
    * `:at` - millisecond timestamp at which the flush occurred.
    * `:changes` - map of `%{series_name => Summary.t()}` for all matching series modified since the last sent frame.
  """

  alias Trysac.LiveviewRealtimeDashboard.Summary

  @enforce_keys [:seq, :at, :changes]
  defstruct [:seq, :at, :changes]

  @type t :: %__MODULE__{
          seq: pos_integer(),
          at: integer(),
          changes: %{String.t() => Summary.t()}
        }

  @doc """
  Converts a `%Frame{}` struct into a plain map with string keys and plain values ready for JSON encoding.

  ## Examples

      iex> summary = %Trysac.LiveviewRealtimeDashboard.Summary{
      ...>   count: 1,
      ...>   sum: 42,
      ...>   min: 42,
      ...>   max: 42,
      ...>   last: 42,
      ...>   rate_per_min: 1.0
      ...> }
      iex> frame = %Trysac.LiveviewRealtimeDashboard.Frame{
      ...>   seq: 1,
      ...>   at: 1_000,
      ...>   changes: %{"cpu.host1" => summary}
      ...> }
      iex> Trysac.LiveviewRealtimeDashboard.Frame.to_map(frame)
      %{
        "seq" => 1,
        "at" => 1_000,
        "changes" => %{
          "cpu.host1" => %{
            "count" => 1,
            "sum" => 42,
            "min" => 42,
            "max" => 42,
            "last" => 42,
            "rate_per_min" => 1.0
          }
        }
      }

  """
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{seq: seq, at: at, changes: changes}) do
    plain_changes =
      Map.new(changes, fn {series, summary} ->
        {series, Summary.to_map(summary)}
      end)

    %{
      "seq" => seq,
      "at" => at,
      "changes" => plain_changes
    }
  end
end

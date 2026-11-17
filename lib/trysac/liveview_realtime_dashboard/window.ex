defmodule Trysac.LiveviewRealtimeDashboard.Window do
  @moduledoc """
  Pure rolling bucketed time window for aggregating numeric metric updates.

  A window divides time into fixed-width buckets of `bucket_ms` milliseconds and retains
  buckets that fall within `window_ms`. A bucket with start timestamp `bucket_start`
  is active at `now_ms` while `bucket_start + window_ms > now_ms`.
  """

  alias Trysac.LiveviewRealtimeDashboard.Error
  alias Trysac.LiveviewRealtimeDashboard.Summary

  @max_buckets 3_600

  @type bucket :: %{
          count: pos_integer(),
          sum: number(),
          min: number(),
          max: number()
        }

  @enforce_keys [:window_ms, :bucket_ms]
  defstruct [
    :window_ms,
    :bucket_ms,
    buckets: %{},
    last: nil,
    last_ts: nil,
    max_ts: nil
  ]

  @type t :: %__MODULE__{
          window_ms: pos_integer(),
          bucket_ms: pos_integer(),
          buckets: %{integer() => bucket()},
          last: number() | nil,
          last_ts: integer() | nil,
          max_ts: integer() | nil
        }

  @doc """
  Creates a new rolling window of length `window_ms` divided into buckets of `bucket_ms`.

  Raises `Trysac.LiveviewRealtimeDashboard.Error` with code `:invalid_option` if
  `window_ms` or `bucket_ms` is not a positive integer, if `window_ms` is not an exact
  multiple of `bucket_ms`, or if `div(window_ms, bucket_ms) > 3_600`.

  ## Examples

      iex> w = Trysac.LiveviewRealtimeDashboard.Window.new(60_000, 1_000)
      iex> {w.window_ms, w.bucket_ms}
      {60_000, 1_000}

  """
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(window_ms, bucket_ms) do
    validate_dimensions!(window_ms, bucket_ms)
    %__MODULE__{window_ms: window_ms, bucket_ms: bucket_ms}
  end

  @doc """
   validates `window_ms` and `bucket_ms` dimensions, raising `Error` on failure.
  """
  @spec validate_dimensions!(term(), term()) :: :ok
  def validate_dimensions!(window_ms, bucket_ms) do
    cond do
      not is_integer(bucket_ms) or bucket_ms <= 0 ->
        raise Error.new(
                :invalid_option,
                "bucket_ms must be a positive integer, got: #{Error.preview(bucket_ms)}"
              )

      not is_integer(window_ms) or window_ms <= 0 ->
        raise Error.new(
                :invalid_option,
                "window_ms must be a positive integer, got: #{Error.preview(window_ms)}"
              )

      rem(window_ms, bucket_ms) != 0 ->
        raise Error.new(
                :invalid_option,
                "window_ms (#{window_ms}) must be a multiple of bucket_ms (#{bucket_ms})"
              )

      div(window_ms, bucket_ms) > @max_buckets ->
        raise Error.new(
                :invalid_option,
                "window cannot exceed #{@max_buckets} buckets, got: #{div(window_ms, bucket_ms)}"
              )

      true ->
        :ok
    end
  end

  @doc """
  Adds a sample `value` at `ts_ms` (in milliseconds) to `window`.

  If the sample falls into a bucket that is already expired relative to the highest
  timestamp seen by this window (`bucket_start + window_ms <= max_ts`), the sample is
  ignored as late.

  Raises `Trysac.LiveviewRealtimeDashboard.Error` with `:invalid_value` if `value` is not
  a number, or `:invalid_option` if `ts_ms` is not an integer.

  ## Examples

      iex> w = Trysac.LiveviewRealtimeDashboard.Window.new(60_000, 1_000)
      iex> w = Trysac.LiveviewRealtimeDashboard.Window.add(w, 1_000, 10)
      iex> Trysac.LiveviewRealtimeDashboard.Window.summary(w, 1_500).count
      1

  """
  @spec add(t(), integer(), number()) :: t()
  def add(%__MODULE__{} = window, ts_ms, value) do
    validate_add_args!(ts_ms, value)

    new_max_ts =
      case window.max_ts do
        nil -> ts_ms
        prev -> max(prev, ts_ms)
      end

    b_start = bucket_start(ts_ms, window.bucket_ms)

    if b_start + window.window_ms <= new_max_ts do
      window
    else
      insert_sample(window, b_start, ts_ms, value, new_max_ts)
    end
  end

  defp validate_add_args!(ts_ms, value) do
    if not is_integer(ts_ms) do
      raise Error.new(
              :invalid_option,
              "ts_ms must be an integer, got: #{Error.preview(ts_ms)}"
            )
    end

    if not is_number(value) do
      raise Error.new(
              :invalid_value,
              "value must be an integer or float, got: #{Error.preview(value)}"
            )
    end
  end

  defp insert_sample(%__MODULE__{} = window, b_start, ts_ms, value, new_max_ts) do
    updated_buckets =
      window.buckets
      |> prune_buckets(window.window_ms, new_max_ts)
      |> Map.update(
        b_start,
        %{count: 1, sum: value, min: value, max: value},
        fn b ->
          %{
            count: b.count + 1,
            sum: b.sum + value,
            min: min(b.min, value),
            max: max(b.max, value)
          }
        end
      )

    {new_last, new_last_ts} =
      case window.last_ts do
        nil -> {value, ts_ms}
        prev_ts when ts_ms >= prev_ts -> {value, ts_ms}
        prev_ts -> {window.last, prev_ts}
      end

    %__MODULE__{
      window
      | buckets: updated_buckets,
        last: new_last,
        last_ts: new_last_ts,
        max_ts: new_max_ts
    }
  end

  @doc """
  Computes the `%Summary{}` of active buckets at `now_ms`.

  A bucket is included while `bucket_start + window_ms > now_ms`.

  ## Examples

      iex> w = Trysac.LiveviewRealtimeDashboard.Window.new(60_000, 1_000)
      iex> w = Enum.reduce(1..10, w, fn i, acc ->
      ...>   Trysac.LiveviewRealtimeDashboard.Window.add(acc, (i - 1) * 1_000, i)
      ...> end)
      iex> s = Trysac.LiveviewRealtimeDashboard.Window.summary(w, 9_500)
      iex> {s.count, s.sum, s.min, s.max, s.last}
      {10, 55, 1, 10, 10}

  """
  @spec summary(t(), integer()) :: Summary.t()
  def summary(%__MODULE__{} = window, now_ms) when is_integer(now_ms) do
    window_ms = window.window_ms
    cutoff = now_ms - window_ms

    {count, sum, min_val, max_val} =
      window.buckets
      |> Enum.filter(fn {b_start, _bucket} -> b_start > cutoff end)
      |> Enum.reduce({0, 0, nil, nil}, &accumulate_bucket/2)

    rate_per_min = count * 60_000.0 / window_ms

    %Summary{
      count: count,
      sum: sum,
      min: min_val,
      max: max_val,
      last: window.last,
      rate_per_min: rate_per_min
    }
  end

  def summary(%__MODULE__{}, now_ms) do
    raise Error.new(
            :invalid_option,
            "now_ms must be an integer, got: #{Error.preview(now_ms)}"
          )
  end

  @doc """
  Computes the aligned bucket start timestamp for `ts_ms` and `bucket_ms`.
  """
  @spec bucket_start(integer(), pos_integer()) :: integer()
  def bucket_start(ts_ms, bucket_ms) do
    Integer.floor_div(ts_ms, bucket_ms) * bucket_ms
  end

  defp prune_buckets(buckets, window_ms, ref_ts) do
    Map.reject(buckets, fn {b_start, _bucket} ->
      b_start + window_ms <= ref_ts
    end)
  end

  defp accumulate_bucket({_b_start, b}, {acc_c, acc_s, acc_min, acc_max}) do
    new_min = if acc_min == nil, do: b.min, else: min(acc_min, b.min)
    new_max = if acc_max == nil, do: b.max, else: max(acc_max, b.max)
    {acc_c + b.count, acc_s + b.sum, new_min, new_max}
  end
end

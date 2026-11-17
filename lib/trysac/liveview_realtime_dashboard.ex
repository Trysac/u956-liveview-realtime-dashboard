defmodule Trysac.LiveviewRealtimeDashboard do
  @moduledoc """
  Real-time dashboard hub that folds metric updates into rolling bucketed windows
  and sends each subscriber one coalesced frame per tick, with acknowledgement-based
  flow control.

  The primary modules are:

    * `Trysac.LiveviewRealtimeDashboard.Window` - pure rolling bucketed window state.
    * `Trysac.LiveviewRealtimeDashboard.Summary` - summary aggregate over a window.
    * `Trysac.LiveviewRealtimeDashboard.Frame` - coalesced update frame delivered to subscribers.
    * `Trysac.LiveviewRealtimeDashboard.Hub` - GenServer managing series windows, subscriptions, and flow control.
    * `Trysac.LiveviewRealtimeDashboard.Error` - library exception with machine-readable error codes.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns the package version.

  ## Examples

      iex> Trysac.LiveviewRealtimeDashboard.version()
      "0.1.0"

  """
  @spec version() :: String.t()
  def version, do: @version
end

defmodule Trysac.LiveviewRealtimeDashboard do
  @moduledoc """
  Real-time dashboard hub that folds metric updates into rolling bucketed windows and sends each subscriber one coalesced frame per tick, with acknowledgement-based flow control

  The entry point of the library: its public modules live under `Trysac.LiveviewRealtimeDashboard`.
  """

  @doc """
  The library's version, read from the application specification (the release manager sets it in `mix.exs`).
  """
  @spec version() :: String.t()
  def version do
    :trysac_liveview_realtime_dashboard |> Application.spec(:vsn) |> to_string()
  end
end

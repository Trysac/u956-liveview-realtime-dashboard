defmodule Trysac.LiveviewRealtimeDashboard.Text do
  @moduledoc """
  Text helpers of this library.
  """

  alias Trysac.LiveviewRealtimeDashboard.BlankInputError

  @doc """
  Trims surrounding whitespace and lower-cases the ASCII letters of the text.

  Raises `Trysac.LiveviewRealtimeDashboard.BlankInputError` when nothing is left after trimming, instead of
  returning an empty string.

  ## Examples

      iex> Trysac.LiveviewRealtimeDashboard.Text.normalize("  Hello World ")
      "hello world"

  """
  @spec normalize(String.t()) :: String.t()
  def normalize(input) when is_binary(input) do
    case String.trim(input) do
      "" -> raise BlankInputError
      trimmed -> String.downcase(trimmed, :ascii)
    end
  end
end

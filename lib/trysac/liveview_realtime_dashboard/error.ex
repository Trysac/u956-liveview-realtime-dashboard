defmodule Trysac.LiveviewRealtimeDashboard.Error do
  @moduledoc """
  Exception raised or returned by `Trysac.LiveviewRealtimeDashboard` when invalid
  arguments, options, or resource limits are encountered.

  Every error carries a stable machine-readable `:code`:

    * `:invalid_series` - series name is not a valid string matching `~r/^[a-z0-9_.:-]{1,128}$/`.
    * `:invalid_value` - metric value is not an integer or float.
    * `:invalid_option` - configuration option or timestamp is invalid.
    * `:series_limit` - adding a new series would exceed `max_series`.
    * `:subscriber_limit` - adding a new subscriber would exceed `max_subscribers`.
    * `:unknown_subscription` - subscription reference is not registered.
  """

  @type code ::
          :invalid_series
          | :invalid_value
          | :invalid_option
          | :series_limit
          | :subscriber_limit
          | :unknown_subscription

  @type t :: %__MODULE__{
          code: code(),
          message: String.t()
        }

  defexception [:code, :message]

  @max_input_preview 200

  @doc """
  Constructs a `Trysac.LiveviewRealtimeDashboard.Error` with a truncated input preview
  guaranteed to contain at most 200 characters of caller input.
  """
  @spec new(code(), String.t()) :: t()
  def new(code, message) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message}
  end

  @doc """
  Formats an arbitrary term for safe inclusion in an error message, truncating its
  representation to at most 200 characters.
  """
  @spec preview(term()) :: String.t()
  def preview(term) do
    inspected =
      case term do
        bin when is_binary(bin) -> inspect(String.slice(bin, 0, @max_input_preview))
        other -> inspect(other, printable_limit: @max_input_preview, limit: 20)
      end

    if String.length(inspected) > @max_input_preview do
      String.slice(inspected, 0, @max_input_preview)
    else
      inspected
    end
  end
end

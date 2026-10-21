defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  Build a client with `new/1`, then fetch forecasts with `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder host. Replace with the API's real root URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_receive_timeout 15_000

  @enforce_keys [:api_key, :base_url, :receive_timeout]
  # Keeps the key out of logs, crash reports, and IEx output.
  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :receive_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - root URL of the API. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for a response. Defaults to `#{@default_receive_timeout}`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts,
        api_key: nil,
        base_url: @default_base_url,
        receive_timeout: @default_receive_timeout
      )

    %__MODULE__{
      api_key: validate_api_key!(opts[:api_key]),
      base_url: validate_base_url!(opts[:base_url]),
      receive_timeout: validate_receive_timeout!(opts[:receive_timeout])
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success. Returns
  `{:error, %WeatherClient.Error{}}` when the API responds with an error
  status or the request cannot complete.

  ## Examples

      client = WeatherClient.new(api_key: "key")
      WeatherClient.forecast(client, 52.52, 13.41)
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> send_request(lat, lon)
    |> handle_response()
  end

  defp send_request(%__MODULE__{} = client, lat, lon) do
    Req.get(
      url: forecast_url(client.base_url),
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.receive_timeout
    )
  end

  defp forecast_url(base_url), do: String.trim_trailing(base_url, "/") <> "/forecast"

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: parse_forecast(body)

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{status: status, message: error_message(body)}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{message: Exception.message(exception)}}
  end

  defp parse_forecast(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(_body) do
    {:error, %Error{status: 200, message: "unexpected forecast response"}}
  end

  # Gateways and proxies return HTML or empty bodies on errors, so anything
  # without an "error" string gets a generic message.
  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: "unexpected error response"

  defp validate_api_key!(api_key) when is_binary(api_key) and api_key != "", do: api_key
  defp validate_base_url!(base_url) when is_binary(base_url), do: base_url
  defp validate_receive_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when a forecast request fails.

  `status` is the HTTP status code, or `nil` when no response was received
  (for example, on a timeout or connection failure).
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          message: String.t()
        }
end

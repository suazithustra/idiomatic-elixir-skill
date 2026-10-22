defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast for one location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  The reason a forecast request failed.

  `status` is the HTTP status the API returned. It is `nil` when no response
  arrived, and `reason` then holds the transport exception.
  """

  defexception [:status, :message, :reason]

  @type t :: %__MODULE__{
          status: pos_integer() | nil,
          message: String.t(),
          reason: Exception.t() | nil
        }
end

defmodule WeatherClient do
  @moduledoc """
  Fetches forecasts from a weather HTTP API.

  Build a client with `new/1` and reuse it for every request:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  Failed requests return `{:error, %WeatherClient.Error{}}`.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_receive_timeout 15_000

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :receive_timeout]
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
    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_receive_timeout}`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    defaults = [
      api_key: nil,
      base_url: @default_base_url,
      receive_timeout: @default_receive_timeout
    ]

    opts = Keyword.validate!(opts, defaults)
    build(opts[:api_key], opts[:base_url], opts[:receive_timeout])
  end

  @doc """
  Fetches the forecast for a latitude and longitude.

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}} =
        WeatherClient.forecast(client, 52.52, 13.41)
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    case get_forecast(client, lat, lon) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, to_forecast(body)}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, api_error(status, body)}
      {:error, exception} -> {:error, transport_error(exception)}
    end
  end

  defp build(api_key, base_url, receive_timeout)
       when is_binary(api_key) and api_key != "" and is_binary(base_url) and
              is_integer(receive_timeout) and receive_timeout > 0 do
    %__MODULE__{
      api_key: api_key,
      base_url: String.trim_trailing(base_url, "/"),
      receive_timeout: receive_timeout
    }
  end

  defp get_forecast(client, lat, lon) do
    options = [
      url: client.base_url <> "/forecast",
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.receive_timeout
    ]

    Req.get(options)
  end

  defp to_forecast(body) do
    %{"temperature_c" => temp_c, "condition" => condition, "wind_kph" => wind_kph} = body
    %Forecast{temperature_c: temp_c, condition: condition, wind_kph: wind_kph}
  end

  defp api_error(status, %{"error" => message}) do
    %Error{status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{status: status, message: "request failed with HTTP status #{status}"}
  end

  defp transport_error(exception) do
    %Error{message: Exception.message(exception), reason: exception}
  end
end

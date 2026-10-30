defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when a forecast request fails.

  `reason` is one of:

    * `:api` - the API answered with a non-2xx status. `status` holds the HTTP
      status and `message` the `"error"` text from the response, when it had one.
    * `:invalid_response` - the API answered with a 2xx status but the body was
      not a forecast.
    * `:transport` - the request never got a response (timeout, connection
      refused, and so on). `message` describes the cause.
  """

  @type reason :: :api | :invalid_response | :transport

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          message: String.t()
        }

  defexception [:reason, :status, message: "weather request failed"]
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location.

  Temperature is in degrees Celsius and wind speed in kilometres per hour.
  """

  alias WeatherClient.Error

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_json(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(%{
        "temperature_c" => temperature_c,
        "condition" => condition,
        "wind_kph" => wind_kph
      })
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def from_json(_body) do
    {:error, %Error{reason: :invalid_response, message: "response is not a forecast"}}
  end
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  ## Examples

      client = WeatherClient.new("my-api-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c

  A client is a plain struct, so several clients with different keys, base URLs
  or timeouts can be used in the same application. Nothing is read from the
  application environment.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout]
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client that sends `api_key` in the `x-api-key` header of every request.

  ## Options

    * `:base_url` - base URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`.

  ## Examples

      iex> client = WeatherClient.new("key", timeout: 2_000)
      iex> client.timeout
      2000
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts = Keyword.validate!(opts, base_url: @default_base_url, timeout: @default_timeout)
    build(api_key, opts[:base_url], opts[:timeout])
  end

  @doc """
  Fetches the current forecast for a latitude and longitude, in degrees.

  Returns `{:error, %WeatherClient.Error{}}` when the request fails.

  ## Examples

      WeatherClient.forecast(client, 52.52, 13.41)
      #=> {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lon) and lon >= -180 and
             lon <= 180 do
    client
    |> request(lat, lon)
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} ->
        forecast

      {:error, error} ->
        raise error
    end
  end

  defp build(api_key, base_url, timeout)
       when is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout}
  end

  defp request(client, lat, lon) do
    req =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    Req.get(req, url: "/forecast", params: [lat: lat, lon: lon])
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    Forecast.from_json(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when is_binary(message) do
    {:error, %Error{reason: :api, status: status, message: message}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, %Error{reason: :api, status: status, message: "unexpected status #{status}"}}
  end

  defp handle_response({:error, exception}) when is_exception(exception) do
    {:error, %Error{reason: :transport, message: Exception.message(exception)}}
  end
end

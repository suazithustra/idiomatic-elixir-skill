defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Settings can be set in application config and overridden per call:

      config :weather_client,
        api_key: System.get_env("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 15_000

  Per-call options take precedence over application config.
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder. Set `:base_url` in config to the real API host.
  @default_base_url "https://weather.example.com"
  @default_timeout 15_000

  @doc """
  Fetches the current forecast for a latitude and longitude.

  ## Options

    * `:api_key` - sent in the `x-api-key` header. Required, unless set in config.
    * `:base_url` - base URL of the API. Defaults to the configured value.
    * `:timeout` - receive timeout in milliseconds. Defaults to the configured value.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` on failure.

  ## Examples

      {:ok, forecast} = WeatherClient.forecast(52.52, 13.41, api_key: "key")
      forecast.temperature_c
      #=> 21.5

  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ []) do
    with :ok <- validate_coordinates(lat, lon),
         {:ok, config} <- build_config(opts),
         {:ok, body} <- get_forecast(config, lat, lon) do
      Forecast.from_body(body)
    end
  end

  defp validate_coordinates(lat, lon)
       when is_number(lat) and lat >= -90 and lat <= 90 and
              is_number(lon) and lon >= -180 and lon <= 180,
       do: :ok

  defp validate_coordinates(_lat, _lon) do
    {:error,
     %Error{
       type: :invalid_coordinates,
       message: "latitude must be between -90 and 90, longitude between -180 and 180"
     }}
  end

  defp build_config(opts) do
    app = Application.get_all_env(:weather_client)

    api_key = Keyword.get(opts, :api_key) || Keyword.get(app, :api_key)
    base_url = Keyword.get(opts, :base_url) || Keyword.get(app, :base_url, @default_base_url)
    timeout = Keyword.get(opts, :timeout) || Keyword.get(app, :timeout, @default_timeout)

    if is_binary(api_key) and api_key != "" do
      {:ok,
       %{
         api_key: api_key,
         base_url: String.trim_trailing(base_url, "/"),
         timeout: timeout
       }}
    else
      {:error, %Error{type: :missing_api_key, message: "no API key given or configured"}}
    end
  end

  defp get_forecast(config, lat, lon) do
    result =
      Req.get(config.base_url <> "/forecast",
        params: [lat: lat, lon: lon],
        headers: [{"x-api-key", config.api_key}],
        receive_timeout: config.timeout
      )

    case result do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{type: :api, status: status, message: api_error_message(body, status)}}

      {:error, exception} ->
        {:error, %Error{type: :transport, message: Exception.message(exception)}}
    end
  end

  defp api_error_message(%{"error" => message}, _status) when is_binary(message), do: message
  defp api_error_message(_body, status), do: "HTTP #{status}"
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.

    * `:temperature_c` - temperature in degrees Celsius.
    * `:condition` - short description, such as `"cloudy"`.
    * `:wind_kph` - wind speed in kilometres per hour.
  """

  alias WeatherClient.Error

  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_body(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_body(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
      when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  def from_body(body) do
    {:error, %Error{type: :decode, message: "unexpected response body: #{inspect(body)}"}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient`.

    * `:type` - one of `:invalid_coordinates`, `:missing_api_key`, `:api`,
      `:transport`, or `:decode`.
    * `:status` - HTTP status code, set for `:api` errors only.
    * `:message` - human-readable description.
  """

  defexception [:type, :status, :message]

  @type t :: %__MODULE__{
          type: atom(),
          status: pos_integer() | nil,
          message: String.t()
        }
end

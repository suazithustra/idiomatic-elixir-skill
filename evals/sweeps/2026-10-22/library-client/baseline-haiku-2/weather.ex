defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API, built on Req.

  Configure defaults in your application config. Only `:api_key` is required:

      config :weather_client,
        api_key: System.get_env("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 5_000

  Each value can also be passed per call as an option with the same name.
  """

  alias WeatherClient.Forecast

  @default_base_url "https://weather.example.com"
  @default_timeout 5_000

  @type error ::
          :missing_api_key
          | {:api_error, pos_integer(), String.t()}
          | {:transport_error, Exception.t()}
          | {:unexpected_response, term()}

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or `{:error, reason}`
  where `reason` is one of the values in `t:error/0`.

  ## Options

    * `:api_key` - overrides the configured API key
    * `:base_url` - overrides the configured base URL
    * `:timeout` - receive timeout in milliseconds, overrides the configured value

  ## Examples

      WeatherClient.forecast(51.5, -0.12)
      WeatherClient.forecast(51.5, -0.12, timeout: 10_000)
  """
  @spec forecast(number(), number(), keyword()) :: {:ok, Forecast.t()} | {:error, error()}
  def forecast(lat, lon, opts \\ [])
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    config = config(opts)

    with {:ok, api_key} <- fetch_api_key(config),
         {:ok, response} <- request(config, api_key, lat, lon) do
      handle_response(response)
    end
  end

  defp config(opts) do
    app = Application.get_all_env(:weather_client)

    %{
      api_key: Keyword.get(opts, :api_key, app[:api_key]),
      base_url: Keyword.get(opts, :base_url, app[:base_url] || @default_base_url),
      timeout: Keyword.get(opts, :timeout, app[:timeout] || @default_timeout)
    }
  end

  defp fetch_api_key(%{api_key: api_key}) when is_binary(api_key) and api_key != "",
    do: {:ok, api_key}

  defp fetch_api_key(_config), do: {:error, :missing_api_key}

  defp request(config, api_key, lat, lon) do
    req =
      Req.new(
        receive_timeout: config.timeout,
        headers: [{"x-api-key", api_key}]
      )

    url = String.trim_trailing(config.base_url, "/") <> "/forecast"

    case Req.get(req, url: url, params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    case decode(body) do
      {:ok, %{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind}}
      when is_number(temperature) and is_binary(condition) and is_number(wind) ->
        {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}

      _ ->
        {:error, {:unexpected_response, body}}
    end
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    {:error, {:api_error, status, error_message(body)}}
  end

  defp error_message(body) do
    case decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ -> "unknown error"
    end
  end

  # Req decodes JSON responses automatically; this also covers bodies that
  # arrive as raw binaries (for example, when the content type is not JSON).
  defp decode(body) when is_map(body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_body), do: :error
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  Current weather conditions for one location.

    * `:temperature_c` - temperature in degrees Celsius
    * `:condition` - short description, such as `"cloudy"`
    * `:wind_kph` - wind speed in kilometres per hour
  """

  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

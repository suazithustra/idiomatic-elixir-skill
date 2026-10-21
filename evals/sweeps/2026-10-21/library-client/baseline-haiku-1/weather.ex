defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Settings can be set per call or in the application config:

      config :weather_client,
        api_key: System.get_env("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 15_000

  Options passed to `forecast/3` override the config values.
  """

  alias WeatherClient.Forecast

  @default_base_url "https://weather.example.com"
  @default_timeout 15_000

  @type error ::
          :missing_api_key
          | :invalid_coordinates
          | {:api_error, pos_integer(), String.t()}
          | {:unexpected_response, term()}
          | {:transport_error, Exception.t()}

  @doc """
  Returns the current forecast for the given latitude and longitude.

  ## Options

    * `:api_key` - sent in the `x-api-key` header. Defaults to the `:api_key` config.
    * `:base_url` - API root URL, without a trailing path. Defaults to the `:base_url` config.
    * `:timeout` - receive timeout in milliseconds. Defaults to the `:timeout` config.

  ## Return values

    * `{:ok, %WeatherClient.Forecast{}}` on success.
    * `{:error, :missing_api_key}` when no API key is given or configured.
    * `{:error, :invalid_coordinates}` when `lat` is outside -90..90 or `lon` is outside -180..180.
    * `{:error, {:api_error, status, message}}` when the API returns a 4xx or 5xx status.
    * `{:error, {:unexpected_response, body}}` when a success response has an unexpected body.
    * `{:error, {:transport_error, exception}}` when the request fails (for example, a timeout).
  """
  @spec forecast(number(), number(), keyword()) :: {:ok, Forecast.t()} | {:error, error()}
  def forecast(lat, lon, opts \\ []) do
    with :ok <- validate_coordinates(lat, lon),
         {:ok, api_key} <- fetch_api_key(opts) do
      base_url = opts |> Keyword.get(:base_url, config(:base_url, @default_base_url)) |> String.trim_trailing("/")

      opts
      |> build_request(api_key)
      |> Req.get(url: base_url <> "/forecast", params: [lat: lat, lon: lon])
      |> handle_result()
    end
  end

  defp validate_coordinates(lat, lon)
       when is_number(lat) and is_number(lon) and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180,
       do: :ok

  defp validate_coordinates(_lat, _lon), do: {:error, :invalid_coordinates}

  defp fetch_api_key(opts) do
    case Keyword.get(opts, :api_key, config(:api_key)) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp build_request(opts, api_key) do
    Req.new(
      receive_timeout: Keyword.get(opts, :timeout, config(:timeout, @default_timeout)),
      headers: [{"x-api-key", api_key}]
    )
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    case Forecast.from_map(body) do
      {:ok, forecast} -> {:ok, forecast}
      :error -> {:error, {:unexpected_response, body}}
    end
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}}) when status >= 400 do
    {:error, {:api_error, status, error_message(body)}}
  end

  defp handle_result({:ok, %Req.Response{body: body}}), do: {:error, {:unexpected_response, body}}

  defp handle_result({:error, exception}), do: {:error, {:transport_error, exception}}

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body), do: body
  defp error_message(body), do: inspect(body)

  defp config(key, default \\ nil), do: Application.get_env(:weather_client, key, default)
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.

    * `:temperature_c` - temperature in degrees Celsius.
    * `:condition` - a short description, such as `"cloudy"`.
    * `:wind_kph` - wind speed in kilometres per hour.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def from_map(_body), do: :error
end

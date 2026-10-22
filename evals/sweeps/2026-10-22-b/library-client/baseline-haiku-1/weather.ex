defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  ## Configuration

      config :weather_client,
        api_key: System.get_env("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 10_000

  Each setting can also be passed per call as an option to `forecast/3`.
  """

  alias WeatherClient.Forecast

  @default_base_url "https://weather.example.com"
  @default_timeout 10_000

  @type error ::
          :missing_api_key
          | {:api_error, status :: non_neg_integer(), message :: String.t() | nil}
          | {:transport_error, Exception.t()}
          | {:unexpected_response, term()}

  @doc """
  Fetches the current forecast for the given coordinates.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or `{:error, reason}`.

  ## Options

    * `:api_key` - overrides the configured API key
    * `:base_url` - overrides the configured base URL (scheme and host, e.g. `"https://weather.example.com"`)
    * `:timeout` - receive timeout in milliseconds

  ## Examples

      WeatherClient.forecast(51.5, -0.12)
      WeatherClient.forecast(51.5, -0.12, timeout: 5_000)
  """
  @spec forecast(number(), number(), keyword()) :: {:ok, Forecast.t()} | {:error, error()}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) do
    with {:ok, api_key} <- fetch_api_key(opts),
         {:ok, response} <- get_forecast(api_key, lat, lon, opts) do
      handle_response(response)
    end
  end

  defp fetch_api_key(opts) do
    case Keyword.get(opts, :api_key) || config(:api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp get_forecast(api_key, lat, lon, opts) do
    client =
      Req.new(
        base_url: Keyword.get(opts, :base_url) || config(:base_url) || @default_base_url,
        receive_timeout: Keyword.get(opts, :timeout) || config(:timeout) || @default_timeout,
        headers: [{"x-api-key", api_key}]
      )

    case Req.get(client, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  defp handle_response(%{status: status, body: body}) when status in 200..299 do
    with {:ok, data} <- decode_body(body), do: parse_forecast(data)
  end

  defp handle_response(%{status: status, body: body}) do
    {:error, {:api_error, status, error_message(body)}}
  end

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(other), do: {:error, {:unexpected_response, other}}

  defp error_message(body) do
    case decode_body(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ -> nil
    end
  end

  # Req decodes JSON responses by default; this covers bodies it left as binaries.
  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, {:unexpected_response, body}}
    end
  end

  defp decode_body(body), do: {:error, {:unexpected_response, body}}

  defp config(key), do: Application.get_env(:weather_client, key)
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A current weather forecast returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

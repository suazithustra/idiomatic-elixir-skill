defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for a single location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  ## Configuration

  Settings can be set in the application environment or passed per call.
  Per-call options take precedence.

    * `:api_key` - required, sent in the `x-api-key` header
    * `:base_url` - origin of the API without a trailing slash,
      defaults to `"https://api.weather.example.com"`
    * `:timeout` - receive timeout in milliseconds, defaults to `10_000`

  ## Example

      config :weather_client, api_key: System.fetch_env!("WEATHER_API_KEY")

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5}} =
        WeatherClient.forecast(51.5, -0.12)
  """

  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout 10_000

  @type error ::
          :missing_api_key
          | {:http_status, non_neg_integer(), String.t()}
          | {:unexpected_response, term()}
          | {:transport, Exception.t()}

  @doc """
  Fetches the current forecast for the given coordinates.

  Returns `{:ok, forecast}` on success, or `{:error, reason}` where `reason`
  is one of the `t:error/0` variants.
  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, error()}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) do
    with {:ok, req} <- new_request(opts) do
      req
      |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
      |> handle_result()
    end
  end

  defp new_request(opts) do
    case Keyword.get(opts, :api_key, config(:api_key)) do
      api_key when is_binary(api_key) and api_key != "" ->
        {:ok,
         Req.new(
           base_url: Keyword.get(opts, :base_url, config(:base_url, @default_base_url)),
           receive_timeout: Keyword.get(opts, :timeout, config(:timeout, @default_timeout)),
           headers: [{"x-api-key", api_key}]
         )}

      _ ->
        {:error, :missing_api_key}
    end
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    parse_forecast(body)
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http_status, status, error_message(body)}}
  end

  defp handle_result({:error, exception}) do
    {:error, {:transport, exception}}
  end

  defp parse_forecast(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> build_forecast(json)
      {:error, _} -> {:error, {:unexpected_response, body}}
    end
  end

  defp parse_forecast(body), do: build_forecast(body)

  defp build_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok,
     %Forecast{
       temperature_c: temperature_c,
       condition: condition,
       wind_kph: wind_kph
     }}
  end

  defp build_forecast(body), do: {:error, {:unexpected_response, body}}

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(body), do: inspect(body)

  defp config(key, default \\ nil) do
    Application.get_env(:weather_client, key, default)
  end
end

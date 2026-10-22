defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Settings come from the `:weather_client` application environment and can
  be overridden per call with the same keys:

    * `:api_key` - required, sent in the `x-api-key` header
    * `:base_url` - defaults to `#{"https://api.weather.example.com"}`
    * `:timeout` - receive timeout in milliseconds, defaults to `15_000`

      config :weather_client, api_key: System.fetch_env!("WEATHER_API_KEY")

      WeatherClient.forecast(59.33, 18.07, base_url: "http://localhost:4000")

  Errors are returned as tagged tuples:

    * `{:error, {:api_error, status, message}}` - the API answered with a 4xx/5xx
    * `{:error, {:transport_error, exception}}` - the request never got a response
    * `{:error, {:unexpected_body, body}}` - a 200 response with an unexpected shape
  """

  @default_base_url "https://api.weather.example.com"
  @default_timeout 15_000

  defmodule Forecast do
    @moduledoc "A weather forecast for a single location."

    @enforce_keys [:temperature_c, :condition, :wind_kph]
    defstruct [:temperature_c, :condition, :wind_kph]

    @type t :: %__MODULE__{
            temperature_c: number(),
            condition: String.t(),
            wind_kph: number()
          }
  end

  @doc """
  Fetches the current forecast for the given coordinates.

  ## Examples

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy"}} =
        WeatherClient.forecast(51.5, -0.12)
  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()}
          | {:error, {:api_error, non_neg_integer(), term()}}
          | {:error, {:transport_error, Exception.t()}}
          | {:error, {:unexpected_body, term()}}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) do
    config = config(opts)

    req =
      Req.new(
        base_url: config.base_url,
        receive_timeout: config.timeout,
        headers: [{"x-api-key", config.api_key}]
      )

    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_forecast(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, error_message(body)}}

      {:error, exception} ->
        {:error, {:transport_error, exception}}
    end
  end

  defp config(opts) do
    settings = Keyword.merge(Application.get_all_env(:weather_client), opts)

    api_key =
      Keyword.get(settings, :api_key) ||
        raise ArgumentError, "missing :api_key for :weather_client"

    %{
      api_key: api_key,
      base_url: Keyword.get(settings, :base_url, @default_base_url),
      timeout: Keyword.get(settings, :timeout, @default_timeout)
    }
  end

  defp parse_forecast(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_forecast(decoded)
      {:error, _} -> {:error, {:unexpected_body, body}}
    end
  end

  defp parse_forecast(%{
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

  defp parse_forecast(body), do: {:error, {:unexpected_body, body}}

  defp error_message(%{"error" => message}), do: message
  defp error_message(body), do: body
end

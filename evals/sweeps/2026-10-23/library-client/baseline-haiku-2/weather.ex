defmodule WeatherClient do
  @moduledoc """
  Client for a weather HTTP API, built on Req (an Elixir HTTP client).

  ## Configuration

      config :weather_client,
        base_url: "https://api.example.com",
        timeout: 5_000,
        api_key: System.get_env("WEATHER_API_KEY")

  `:base_url` and `:timeout` (milliseconds) can be overridden per call.
  `:api_key` is required and is sent in the `x-api-key` header.
  """

  alias WeatherClient.Forecast

  @defaults [
    base_url: "https://api.example.com",
    timeout: 5_000,
    api_key: nil
  ]

  @type error ::
          :missing_api_key
          | :invalid_coordinates
          | {:api_error, status :: non_neg_integer(), message :: String.t()}
          | {:unexpected_response, term()}
          | {:transport_error, Exception.t()}

  @doc """
  Fetches the current forecast for a latitude and longitude.

  ## Options

    * `:base_url` - API base URL. Defaults to the configured value.
    * `:timeout` - receive timeout in milliseconds. Defaults to the configured value.
    * `:api_key` - API key. Defaults to the configured value.

  ## Examples

      iex> WeatherClient.forecast(52.52, 13.41)
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, error()}
  def forecast(lat, lon, opts \\ []) do
    settings = settings(opts)

    with :ok <- validate_coordinates(lat, lon),
         {:ok, api_key} <- fetch_api_key(settings),
         {:ok, response} <- get_forecast(lat, lon, settings, api_key) do
      handle_response(response)
    end
  end

  defp settings(opts) do
    @defaults
    |> Keyword.merge(Application.get_all_env(:weather_client))
    |> Keyword.merge(opts)
    |> Keyword.take([:base_url, :timeout, :api_key])
  end

  defp validate_coordinates(lat, lon)
       when is_number(lat) and is_number(lon) and
              lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180,
       do: :ok

  defp validate_coordinates(_lat, _lon), do: {:error, :invalid_coordinates}

  defp fetch_api_key(settings) do
    case settings[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp get_forecast(lat, lon, settings, api_key) do
    base_url = String.trim_trailing(settings[:base_url], "/")

    Req.get(
      url: base_url <> "/forecast",
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", api_key}],
      receive_timeout: settings[:timeout]
    )
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    with {:ok, data} <- decode(body) do
      parse_forecast(data)
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:api_error, status, error_message(body)}}
  end

  defp handle_response({:error, exception}) do
    {:error, {:transport_error, exception}}
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

  defp parse_forecast(data), do: {:error, {:unexpected_response, data}}

  defp error_message(body) do
    case decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ when is_binary(body) -> body
      _ -> inspect(body)
    end
  end

  # Req decodes JSON automatically when the content type says so.
  # This handles the case where it returns the raw string instead.
  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, {:unexpected_response, body}}
    end
  end

  defp decode(body), do: {:error, {:unexpected_response, body}}
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  Current weather conditions returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

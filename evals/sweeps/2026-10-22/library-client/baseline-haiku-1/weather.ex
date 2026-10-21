defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API, built on Req.

  Settings come from the application environment and can be overridden
  per call:

      config :weather_client,
        api_key: "secret",
        base_url: "https://api.example.com",
        timeout: 10_000

  Per-call options `:api_key`, `:base_url` and `:timeout` take precedence
  over the application environment.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.example.com"
  @default_timeout 5_000

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns:

    * `{:ok, %WeatherClient.Forecast{}}` on success
    * `{:error, %WeatherClient.Error{}}` for 4xx and 5xx responses
    * `{:error, :missing_api_key}` when no API key is configured
    * `{:error, :invalid_response}` when a 2xx body does not match the expected shape
    * `{:error, exception}` for transport failures, such as timeouts

  ## Options

    * `:api_key` - API key sent in the `x-api-key` header
    * `:base_url` - base URL of the API
    * `:timeout` - receive timeout in milliseconds

  """
  @spec forecast(number(), number(), keyword()) :: {:ok, Forecast.t()} | {:error, term()}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) do
    with {:ok, api_key} <- fetch_api_key(opts),
         req = build_request(api_key, opts),
         {:ok, response} <- Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      handle_response(response)
    end
  end

  defp fetch_api_key(opts) do
    case Keyword.get(opts, :api_key, config(:api_key)) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp build_request(api_key, opts) do
    Req.new(
      base_url: Keyword.get(opts, :base_url, config(:base_url, @default_base_url)),
      receive_timeout: Keyword.get(opts, :timeout, config(:timeout, @default_timeout)),
      headers: [{"x-api-key", api_key}]
    )
  end

  defp handle_response(%Req.Response{status: 200, body: body}) do
    parse_forecast(body)
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    {:error, %Error{status: status, message: error_message(body)}}
  end

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(_body), do: {:error, :invalid_response}

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: "unexpected response"

  defp config(key, default \\ nil), do: Application.get_env(:weather_client, key, default)
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.
  """

  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error response from the weather API (HTTP 4xx or 5xx).

  `message` holds the `"error"` field from the response body, or a generic
  description when the body does not include one.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{status: pos_integer(), message: String.t()}
end

defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API, built on Req.

  Settings can be placed in the application environment and overridden per call:

      config :weather_client,
        api_key: System.get_env("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 5_000

  Options passed to `forecast/3` take precedence over the application environment.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://weather.example.com"
  @default_timeout 5_000

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the request fails.

  ## Options

    * `:api_key` - Sent in the `x-api-key` header. Required, unless set in the
      application environment. Raises `ArgumentError` when missing.
    * `:base_url` - API base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - Receive and connect timeout in milliseconds. Defaults to `#{@default_timeout}`.
    * `:retry` - Passed to Req. Defaults to `false`, so each call makes one request.
    * `:req_options` - Extra options merged into the Req request. `:api_key` and
      `:timeout` take precedence over any matching keys here.

  ## Examples

      WeatherClient.forecast(51.5, -0.12, api_key: "key")
      #=> {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}
  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ [])
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    config = build_config(opts)

    case Req.get(config.url, req_options(config, lat, lon)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_forecast(body)

      {:ok, %Req.Response{} = response} ->
        {:error, api_error(response)}

      {:error, exception} ->
        {:error, %Error{type: :transport, message: Exception.message(exception)}}
    end
  end

  defp build_config(opts) do
    settings = Keyword.merge(Application.get_all_env(:weather_client), opts)

    api_key =
      Keyword.get(settings, :api_key) ||
        raise ArgumentError, "missing :api_key for WeatherClient"

    base_url = Keyword.get(settings, :base_url) || @default_base_url

    %{
      api_key: api_key,
      url: String.trim_trailing(base_url, "/") <> "/forecast",
      timeout: Keyword.get(settings, :timeout) || @default_timeout,
      retry: Keyword.get(settings, :retry, false),
      req_options: Keyword.get(settings, :req_options) || []
    }
  end

  defp req_options(config, lat, lon) do
    Keyword.merge(config.req_options,
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", config.api_key}],
      receive_timeout: config.timeout,
      connect_options: [timeout: config.timeout],
      retry: config.retry
    )
  end

  defp decode_forecast(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_forecast(decoded)
      {:error, _reason} -> {:error, invalid_response("response body is not JSON")}
    end
  end

  defp decode_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp decode_forecast(_body), do: {:error, invalid_response("unexpected forecast shape")}

  defp api_error(%Req.Response{status: status, body: body}) do
    %Error{type: :api, status: status, message: error_message(body, status)}
  end

  defp error_message(%{"error" => message}, _status) when is_binary(message), do: message

  defp error_message(body, status) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _other -> "HTTP #{status}"
    end
  end

  defp error_message(_body, status), do: "HTTP #{status}"

  defp invalid_response(message) do
    %Error{type: :invalid_response, message: message}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast returned by `WeatherClient.forecast/3`."

  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient.forecast/3`.

  `:type` is one of:

    * `:api` - The API returned a 4xx or 5xx status. `:status` holds the HTTP status
      and `:message` holds the `"error"` text from the response body.
    * `:transport` - The request failed before a response arrived, such as a timeout
      or connection error. `:status` is `nil`.
    * `:invalid_response` - The API returned a 2xx response that was not a valid forecast.
      `:status` is `nil`.
  """

  defexception [:type, :status, :message]

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t()
        }
end

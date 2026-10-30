defmodule WeatherClient do
  @moduledoc """
  Client for a public weather forecast HTTP API, built on Req.

  Settings can be set in application config or passed per call:

      config :weather_client,
        api_key: "your-api-key",
        base_url: "https://weather.example.com",
        timeout: 10_000

  `api_key` is required. `base_url` and `timeout` (milliseconds) have defaults.
  Per-call options override the application config.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://weather.example.com"
  @default_timeout 10_000

  @typedoc "Options accepted by `forecast/3`."
  @type option ::
          {:api_key, String.t()}
          | {:base_url, String.t()}
          | {:timeout, pos_integer()}
          | {:req_options, keyword()}

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the request fails, the API returns
  an error status, or the response body is not the expected shape.

  Extra options are passed to `Req.get/2` through `:req_options`.

  ## Examples

      {:ok, forecast} = WeatherClient.forecast(52.52, 13.41, api_key: "key")
      forecast.temperature_c
      #=> 21.5
  """
  @spec forecast(number(), number(), [option()]) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ [])
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    with {:ok, api_key} <- fetch_api_key(opts),
         {:ok, response} <- get_forecast(api_key, lat, lon, opts) do
      handle_response(response)
    end
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly or raises
  `WeatherClient.Error`.
  """
  @spec forecast!(number(), number(), [option()]) :: Forecast.t()
  def forecast!(lat, lon, opts \\ []) do
    case forecast(lat, lon, opts) do
      {:ok, forecast} -> forecast
      {:error, %Error{} = error} -> raise error
    end
  end

  defp fetch_api_key(opts) do
    case config(opts, :api_key, nil) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, %Error{message: "no API key configured"}}
    end
  end

  defp get_forecast(api_key, lat, lon, opts) do
    url = config(opts, :base_url, @default_base_url) |> String.trim_trailing("/")
    timeout = config(opts, :timeout, @default_timeout)
    req_options = Keyword.get(opts, :req_options, [])

    request_options =
      [
        params: [lat: lat, lon: lon],
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout
      ] ++ req_options

    case Req.get(url <> "/forecast", request_options) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, exception} ->
        {:error, %Error{message: Exception.message(exception)}}
    end
  end

  defp handle_response(%Req.Response{status: 200, body: body}) do
    with {:ok, data} <- decode(body) do
      parse_forecast(data)
    end
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    {:error, %Error{status: status, message: error_message(status, body)}}
  end

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(_data) do
    {:error, %Error{status: 200, message: "unexpected response body"}}
  end

  defp error_message(status, body) do
    case decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ -> "request failed with HTTP #{status}"
    end
  end

  # Req decodes JSON automatically when the server sends a JSON content type.
  # This handles bodies that arrive as raw strings anyway.
  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, %Error{message: "response body is not a JSON object"}}
    end
  end

  defp decode(_body), do: {:error, %Error{message: "response body is not a JSON object"}}

  defp config(opts, key, default) do
    Keyword.get_lazy(opts, key, fn ->
      Application.get_env(:weather_client, key, default)
    end)
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast returned by `WeatherClient.forecast/3`."

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error from `WeatherClient`.

  `status` is the HTTP status code when the server responded, and `nil` for
  transport failures (timeouts, connection errors) and local problems such as
  a missing API key.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{status: non_neg_integer() | nil, message: String.t()}
end

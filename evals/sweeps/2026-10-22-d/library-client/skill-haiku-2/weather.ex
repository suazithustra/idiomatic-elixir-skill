defmodule WeatherClient do
  @moduledoc """
  Fetches forecasts from a weather HTTP API.

  Build a client once with `new/1` and reuse it for every request:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder host: replace with the API's real base URL before publishing.
  @default_base_url "https://api.example-weather.com"
  @default_timeout 5_000
  @options [:api_key, base_url: @default_base_url, timeout: @default_timeout]

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{api_key: String.t(), base_url: String.t(), timeout: pos_integer()}

  @doc """
  Builds a client. Raises `ArgumentError` when an option is missing or invalid.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - the API's base URL, without a trailing slash. Defaults to `#{@default_base_url}`.
    * `:timeout` - milliseconds to wait for a response, per attempt. Defaults to `#{@default_timeout}`.
      Req retries transient failures by default, so one call can take longer than this.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, @options)

    %__MODULE__{
      api_key: validate_api_key!(opts[:api_key]),
      base_url: validate_base_url!(opts[:base_url]),
      timeout: validate_timeout!(opts[:timeout])
    }
  end

  @doc """
  Fetches the current forecast for a coordinate.

  Returns `{:error, %WeatherClient.Error{}}` when the API answers with an error status, when no
  response arrives, or when the response body does not have the expected shape.

  ## Examples

      {:ok, %WeatherClient.Forecast{condition: "cloudy"}} =
        WeatherClient.forecast(client, 52.52, 13.41)
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, response} <- get_forecast(client, lat, lon),
         {:ok, body} <- check_status(response) do
      parse_forecast(body)
    end
  end

  defp get_forecast(%__MODULE__{} = client, lat, lon) do
    url = String.trim_trailing(client.base_url, "/") <> "/forecast"
    params = [lat: lat, lon: lon]
    headers = [{"x-api-key", client.api_key}]

    case Req.get(url, params: params, headers: headers, receive_timeout: client.timeout) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, %Error{message: Exception.message(exception)}}
    end
  end

  defp check_status(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, body}
  end

  defp check_status(%Req.Response{status: status, body: body}) do
    {:error, %Error{status: status, message: error_message(body)}}
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: "unexpected error response"

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(body) do
    {:error, %Error{message: "unexpected response body: #{inspect(body)}"}}
  end

  defp validate_api_key!(api_key) when is_binary(api_key) and api_key != "" do
    api_key
  end

  defp validate_api_key!(_api_key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp validate_base_url!(base_url) when is_binary(base_url) do
    base_url
  end

  defp validate_base_url!(_base_url) do
    raise ArgumentError, "expected :base_url to be a string"
  end

  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0 do
    timeout
  end

  defp validate_timeout!(_timeout) do
    raise ArgumentError, "expected :timeout to be a positive integer in milliseconds"
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one coordinate, as returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error from `WeatherClient`.

  `:status` is the HTTP status when the API answered, and `nil` when the request
  failed before a response arrived.
  """

  defexception [:message, :status]

  @type t :: %__MODULE__{message: String.t(), status: pos_integer() | nil}
end

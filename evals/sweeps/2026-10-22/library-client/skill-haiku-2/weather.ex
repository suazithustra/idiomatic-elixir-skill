defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API.

  Build a client with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example/v1"
  @default_timeout 10_000

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct api_key: nil, base_url: @default_base_url, timeout: @default_timeout

  @typedoc "Settings for one API connection."
  @type t :: %__MODULE__{api_key: String.t(), base_url: String.t(), timeout: pos_integer()}

  @doc """
  Builds a client from its settings.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - root URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `#{@default_timeout}`.

  Raises `ArgumentError` when an option has the wrong type.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:api_key, base_url: @default_base_url, timeout: @default_timeout])

    %__MODULE__{
      api_key: validate_api_key!(opts[:api_key]),
      base_url: validate_base_url!(opts[:base_url]),
      timeout: validate_timeout!(opts[:timeout])
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    with {:ok, body} <- get(client, "/forecast", lat: lat, lon: lon),
         {:ok, forecast} <- Forecast.from_body(body) do
      {:ok, forecast}
    end
  end

  @doc """
  Like `forecast/3`, but raises `WeatherClient.Error` when the request fails.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp get(client, path, params) do
    url = client.base_url <> path
    headers = [{"x-api-key", client.api_key}]

    case Req.get(url, params: params, headers: headers, receive_timeout: client.timeout) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.from_response(status, body)}

      {:error, exception} ->
        {:error, Error.transport(exception)}
    end
  end

  defp validate_api_key!(key) when is_binary(key) and key != "", do: key

  defp validate_api_key!(_key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp validate_base_url!(url) when is_binary(url), do: String.trim_trailing(url, "/")

  defp validate_base_url!(_url) do
    raise ArgumentError, "expected :base_url to be a string"
  end

  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout!(_timeout) do
    raise ArgumentError, "expected :timeout to be a positive integer (milliseconds)"
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  Current conditions for one location, as returned by `WeatherClient.forecast/3`.

  * `:temperature_c` - temperature in degrees Celsius.
  * `:condition` - short description such as `"cloudy"`.
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
  @spec from_body(term()) :: {:ok, t()} | {:error, WeatherClient.Error.t()}
  def from_body(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
      when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  def from_body(_body) do
    {:error, %WeatherClient.Error{status: 200, message: "unexpected response body"}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient`.

  `:status` is the HTTP status code, or `nil` when no response arrived
  (for example a connection failure or a timeout). `:message` is the
  `"error"` text from the API when it sent one, otherwise a short description.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{status: pos_integer() | nil, message: String.t()}

  @doc false
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, %{"error" => message}) when is_binary(message) do
    %__MODULE__{status: status, message: message}
  end

  def from_response(status, _body) do
    %__MODULE__{status: status, message: "HTTP #{status}"}
  end

  @doc false
  @spec transport(Exception.t()) :: t()
  def transport(exception) do
    %__MODULE__{status: nil, message: Exception.message(exception)}
  end
end

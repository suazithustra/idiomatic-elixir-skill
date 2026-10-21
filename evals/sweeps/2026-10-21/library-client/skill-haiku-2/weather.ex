defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API.

  Build a client with `new/1`, then fetch a forecast with `forecast/3`:

      client = WeatherClient.new(api_key: "my-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder host: replace with the API's real root URL.
  @default_base_url "https://api.weather.example/v1"
  @default_timeout :timer.seconds(15)

  @derive {Inspect, except: [:api_key]}
  defstruct [:base_url, :api_key, :timeout]

  @typedoc "A configured client. Build one with `new/1`."
  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t(),
          timeout: pos_integer()
        }

  defguardp valid_latitude?(lat) when is_number(lat) and lat >= -90 and lat <= 90
  defguardp valid_longitude?(lon) when is_number(lon) and lon >= -180 and lon <= 180

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - root URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `#{@default_timeout}`.

  Raises `KeyError` when `:api_key` is missing, and `ArgumentError` on unknown options.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:api_key, base_url: @default_base_url, timeout: @default_timeout])

    %__MODULE__{
      base_url: opts |> Keyword.fetch!(:base_url) |> String.trim_trailing("/"),
      api_key: Keyword.fetch!(opts, :api_key),
      timeout: Keyword.fetch!(opts, :timeout)
    }
  end

  @doc """
  Fetches the current forecast for a coordinate.

  Latitude must be between -90 and 90, and longitude between -180 and 180.
  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when valid_latitude?(lat) and valid_longitude?(lon) do
    client
    |> build_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  defp build_request(client) do
    Req.new(
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    )
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    parse_forecast(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, api_error(status, body)}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :transport, message: Exception.message(exception)}}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(_body) do
    {:error, %Error{reason: :unexpected_response, message: "response is missing forecast fields"}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{reason: :api_error, status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{reason: :unexpected_response, status: status, message: "HTTP #{status}"}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc "Current weather conditions for one coordinate."

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
  Error returned when a forecast request fails.

  `reason` is one of:

    * `:api_error` - the API answered 4xx or 5xx with an `"error"` message.
    * `:unexpected_response` - the API answered with a body this client cannot read.
    * `:transport` - no response arrived, for example on a timeout or a refused connection.

  `status` is the HTTP status, or `nil` when there was no response.
  """

  defexception [:reason, :status, :message]

  @type reason :: :api_error | :unexpected_response | :transport

  @type t :: %__MODULE__{
          reason: reason(),
          status: non_neg_integer() | nil,
          message: String.t()
        }
end

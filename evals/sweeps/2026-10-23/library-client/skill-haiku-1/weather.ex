defmodule WeatherClient.Error do
  @moduledoc """
  The reason in `{:error, reason}` when a forecast request fails.

  `:kind` is one of:

    * `:api` - the server answered with an HTTP error status. `:status` is that
      status and `:message` is the `"error"` text from the response body.
    * `:transport` - no response arrived, for example a refused connection or a
      timeout. `:message` describes the cause.
    * `:invalid_response` - the server answered with a success status, but the
      body is not a forecast.
  """

  defexception [:kind, :status, :message]

  @type kind :: :api | :transport | :invalid_response

  @type t :: %__MODULE__{
          kind: kind(),
          status: non_neg_integer() | nil,
          message: String.t()
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location.
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
  Client for the weather forecast HTTP API.

  Build a client with `new/1`, then ask it for a forecast with `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  Every failure comes back as `{:error, %WeatherClient.Error{}}`. The `:kind`
  field tells the caller which kind of failure it was.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder host. Replace it with the real API root before publishing.
  @defaults [base_url: "https://api.weather.example", timeout: 5_000]

  # The API key is a credential, so it stays out of logs and IEx output.
  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client from the given options.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - the API root, without a `/forecast` suffix. Defaults to
      `"#{@defaults[:base_url]}"`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `5000`.

  Raises `KeyError` when `:api_key` is missing, and `ArgumentError` when an
  option is unknown or has the wrong type.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", timeout: 1_000)
      iex> client.timeout
      1000
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:api_key | @defaults])

    client = %__MODULE__{
      api_key: Keyword.fetch!(opts, :api_key),
      base_url: Keyword.fetch!(opts, :base_url),
      timeout: Keyword.fetch!(opts, :timeout)
    }

    validate!(client)
  end

  @doc """
  Fetches the current forecast for a latitude and longitude in decimal degrees.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.

  ## Examples

      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> get_forecast(lat, lon)
    |> handle_response()
  end

  defp validate!(%__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout} = client)
       when is_binary(api_key) and is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    client
  end

  # The message names the options only, never the client, so the key is not printed.
  defp validate!(_client) do
    raise ArgumentError,
          "expected :api_key and :base_url to be strings and :timeout to be a positive integer"
  end

  defp get_forecast(client, lat, lon) do
    url = String.trim_trailing(client.base_url, "/") <> "/forecast"
    headers = [{"x-api-key", client.api_key}]
    params = [lat: lat, lon: lon]

    Req.get(url, headers: headers, params: params, receive_timeout: client.timeout)
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    parse_forecast(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when status >= 400 do
    {:error, %Error{kind: :api, status: status, message: message}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) when status >= 400 do
    {:error, %Error{kind: :api, status: status, message: "request failed with HTTP #{status}"}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, %Error{kind: :invalid_response, status: status, message: "unexpected HTTP status"}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{kind: :transport, message: Exception.message(exception)}}
  end

  defp parse_forecast(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
       when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(_body) do
    {:error, %Error{kind: :invalid_response, status: 200, message: "response is not a forecast"}}
  end
end

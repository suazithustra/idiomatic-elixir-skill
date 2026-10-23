defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

      client = WeatherClient.new(api_key: "secret", timeout: 2_000)
      {:ok, forecast} = WeatherClient.forecast(client, 51.5, -0.12)

  Expected failures, such as an API error or a timeout, come back as
  `{:error, %WeatherClient.Error{}}`. Nothing here raises for them.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  # The key is a credential, so keep it out of logs and IEx output.
  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct [:api_key, base_url: @default_base_url, timeout: @default_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client from options.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - root URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `#{@default_timeout}`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [:api_key, base_url: @default_base_url, timeout: @default_timeout])

    client = struct!(__MODULE__, opts)
    validate!(client)
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the API answers with an error or the request fails.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    request = build_request(client)

    case Req.get(request, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse_forecast(body)
      {:ok, %Req.Response{status: status, body: body}} -> {:error, api_error(status, body)}
      {:error, exception} -> {:error, %Error{message: Exception.message(exception)}}
    end
  end

  defp validate!(%__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout} = client)
       when is_binary(api_key) and is_binary(base_url) and is_integer(timeout) and timeout > 0,
       do: client

  defp build_request(%__MODULE__{} = client) do
    Req.new(
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    )
  end

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       }) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(body) do
    {:error, %Error{status: 200, message: "unexpected response body: #{inspect(body)}"}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message),
    do: %Error{status: status, message: message}

  defp api_error(status, _body),
    do: %Error{status: status, message: "request failed with status #{status}"}
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  Current conditions at a location, as returned by `WeatherClient.forecast/3`.
  """

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

  `status` is the HTTP status the API returned. It is `nil` when no response
  arrived, such as on a timeout or a connection failure.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{
          status: pos_integer() | nil,
          message: String.t()
        }
end

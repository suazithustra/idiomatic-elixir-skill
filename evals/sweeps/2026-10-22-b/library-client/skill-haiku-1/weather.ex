defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API.

  Build a client with `new/2`, then fetch forecasts with `forecast/3`:

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, %WeatherClient.Forecast{}} = WeatherClient.forecast(client, 51.5, -0.12)
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://weather.example.com"
  @default_timeout 15_000

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{api_key: String.t(), base_url: String.t(), timeout: pos_integer()}

  @doc """
  Builds a client that sends `api_key` with every request.

  ## Options

    * `:base_url` - the API's base URL, without a trailing slash. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to `#{@default_timeout}`.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts = Keyword.validate!(opts, base_url: @default_base_url, timeout: @default_timeout)
    build(api_key, opts[:base_url], opts[:timeout])
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    case get_forecast(client, lat, lon) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode_forecast(body)
      {:ok, %Req.Response{status: status, body: body}} -> {:error, api_error(status, body)}
      {:error, exception} -> {:error, transport_error(exception)}
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

  defp build(api_key, base_url, timeout)
       when is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout}
  end

  defp get_forecast(client, lat, lon) do
    client
    |> new_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
  end

  defp new_request(client) do
    Req.new(
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    )
  end

  defp decode_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp decode_forecast(_body) do
    {:error, %Error{message: "unexpected response body"}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{status: status, message: "request failed with status #{status}"}
  end

  defp transport_error(exception) do
    %Error{message: Exception.message(exception), cause: exception}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient`.

  `status` is the HTTP status code, or `nil` when no response was received,
  such as on a timeout. `cause` holds the transport exception in that case.
  """

  defexception [:status, :message, :cause]

  @type t :: %__MODULE__{
          status: pos_integer() | nil,
          message: String.t(),
          cause: Exception.t() | nil
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

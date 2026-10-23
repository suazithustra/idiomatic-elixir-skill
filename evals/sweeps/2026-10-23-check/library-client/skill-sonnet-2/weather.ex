defmodule WeatherClient.Error do
  @moduledoc """
  The reason in an `{:error, reason}` returned by `WeatherClient`.

  `:reason` is one of:

    * `:api_error` - the API answered with a 4xx or 5xx status. `:status` holds
      the status code and `:message` the text of the API's `error` field.
    * `:unexpected_response` - the API answered with a status or body this
      library does not understand.
    * `:transport` - the request did not complete, for example a timeout or a
      refused connection. `:message` describes the failure.
  """

  @type reason :: :api_error | :unexpected_response | :transport

  @type t :: %__MODULE__{
          reason: reason(),
          status: non_neg_integer() | nil,
          message: String.t()
        }

  defexception [:reason, :status, :message]
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

  @doc false
  @spec parse(term()) :: {:ok, t()} | {:error, WeatherClient.Error.t()}
  def parse(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def parse(_body) do
    error = %WeatherClient.Error{
      reason: :unexpected_response,
      message: "the forecast response is missing a field or has a field of the wrong type"
    }

    {:error, error}
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client once with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  The client holds no process and reads no application environment, so one
  application can use several clients with different keys or base URLs.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout]
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: timeout()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header. Required.
    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults
      to `#{@default_timeout}`.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", timeout: 2_000)
      iex> {client.base_url, client.timeout}
      {"https://api.weather.example.com", 2000}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [:api_key, base_url: @default_base_url, timeout: @default_timeout])

    build(opts[:api_key], opts[:base_url], opts[:timeout])
  end

  @doc """
  Fetches the forecast for a latitude and longitude, in degrees.

  Returns `{:error, %WeatherClient.Error{}}` when the API answers with an
  error or the request fails.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lon) and lon >= -180 and
             lon <= 180 do
    req =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, response} -> handle_response(response)
      {:error, exception} -> {:error, transport_error(exception)}
    end
  end

  @doc """
  Like `forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build(api_key, base_url, timeout)
       when is_binary(api_key) and api_key != "" and is_binary(base_url) and
              (timeout == :infinity or (is_integer(timeout) and timeout > 0)) do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout}
  end

  defp handle_response(%Req.Response{status: 200, body: body}), do: Forecast.parse(body)

  defp handle_response(%Req.Response{status: status, body: %{"error" => message}})
       when status >= 400 and is_binary(message) do
    {:error, %Error{reason: :api_error, status: status, message: message}}
  end

  defp handle_response(%Req.Response{status: status}) do
    error = %Error{
      reason: :unexpected_response,
      status: status,
      message: "unexpected response with status #{status}"
    }

    {:error, error}
  end

  defp transport_error(exception) do
    %Error{reason: :transport, message: Exception.message(exception)}
  end
end

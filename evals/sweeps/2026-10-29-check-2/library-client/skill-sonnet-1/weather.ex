defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` when a request fails.

  `:reason` tells the kinds of failure apart:

    * `:api_error` - the API answered with a non-2xx status. `:status` holds it.
    * `:transport` - no response arrived (timeout, connection refused, DNS failure).
    * `:invalid_response` - the API answered 2xx with a body of an unexpected shape.
  """

  @type reason :: :api_error | :transport | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          status: non_neg_integer() | nil,
          message: String.t()
        }

  defexception [:reason, :status, :message]
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast as returned by the weather API.
  """

  alias WeatherClient.Error

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    forecast = %__MODULE__{
      temperature_c: temperature_c,
      condition: condition,
      wind_kph: wind_kph
    }

    {:ok, forecast}
  end

  def parse(_body) do
    {:error, %Error{reason: :invalid_response, message: "unexpected forecast response body"}}
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API, built on `Req`.

      client = WeatherClient.new("my-api-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.condition
      #=> "cloudy"

  A client is a plain struct, so several clients with different keys or base URLs
  can be used side by side.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout]
  defstruct [:api_key, :base_url, :timeout, req_options: []]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options merged into the `Req` request, for example
      `[plug: {Req.Test, WeatherClient}]` in tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", base_url: "http://localhost:4000")
      iex> client.base_url
      "http://localhost:4000"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    build(api_key, opts[:base_url], opts[:timeout], opts[:req_options])
  end

  @doc """
  Fetches the forecast for a latitude and longitude.

  Returns `{:error, %WeatherClient.Error{}}` when the request fails, the API
  answers with an error, or the response body is not a forecast.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    with {:ok, body} <- get(client, "/forecast", lat: lat, lon: lon) do
      Forecast.parse(body)
    end
  end

  @doc """
  Like `forecast/3`, but returns the forecast and raises `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build(api_key, base_url, timeout, req_options)
       when is_binary(base_url) and is_integer(timeout) and timeout > 0 and
              is_list(req_options) do
    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      timeout: timeout,
      req_options: req_options
    }
  end

  defp get(client, path, params) do
    req_options = [
      base_url: client.base_url,
      receive_timeout: client.timeout,
      headers: [{"x-api-key", client.api_key}]
    ]

    response =
      req_options
      |> Req.new()
      |> Req.merge(client.req_options)
      |> Req.get(url: path, params: params)

    handle_response(response)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when is_binary(message) do
    {:error, %Error{reason: :api_error, status: status, message: message}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    message = "unexpected response with status #{status}"
    {:error, %Error{reason: :api_error, status: status, message: message}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :transport, message: Exception.message(exception)}}
  end
end

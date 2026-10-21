defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when a forecast request fails.

  The `:reason` field says where the failure happened:

    * `:api` - the API answered with a non-2xx status. `:status` holds the
      status code and `:message` holds the API's `"error"` text when it sent one.
    * `:invalid_response` - the API answered 2xx but the body was not a forecast.
    * `:transport` - the request never got a response (timeout, connection
      refused, DNS failure). `:exception` holds the underlying exception.
  """

  defexception [:reason, :status, :exception, message: "weather request failed"]

  @type t :: %__MODULE__{
          reason: :api | :invalid_response | :transport,
          status: non_neg_integer() | nil,
          exception: Exception.t() | nil,
          message: String.t()
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A parsed forecast.

  `:condition` is kept as the string the API sent, because the set of
  conditions is defined by the API and may grow.
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
  A small client for the weather HTTP API.

  Build a client once with `new/2`, then pass it to `fetch_forecast/3`:

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, forecast} = WeatherClient.fetch_forecast(client, 52.52, 13.405)
      forecast.temperature_c

  The client holds no processes and reads no application environment, so you
  can build as many differently configured clients as you need.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  defstruct [:api_key, :base_url, :timeout, :req_options]

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
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `plug: {Req.Test, MyStub}` in tests or `retry: false`. Defaults to `[]`.

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

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec fetch_forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def fetch_forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    client
    |> request(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `fetch_forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec fetch_forecast!(t(), number(), number()) :: Forecast.t()
  def fetch_forecast!(%__MODULE__{} = client, lat, lon) do
    case fetch_forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp request(client, request_options) do
    options =
      Keyword.merge(
        [
          base_url: client.base_url,
          headers: [{"x-api-key", client.api_key}],
          receive_timeout: client.timeout
        ],
        client.req_options
      )

    options
    |> Req.new()
    |> Req.get(request_options)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    parse_forecast(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, api_error(status, body)}
  end

  defp handle_response({:error, exception}) do
    {:error,
     %Error{
       reason: :transport,
       exception: exception,
       message: "weather request failed: " <> Exception.message(exception)
     }}
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
    {:error, %Error{reason: :invalid_response, message: "unexpected forecast response body"}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{reason: :api, status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{reason: :api, status: status, message: "weather API returned status #{status}"}
  end
end

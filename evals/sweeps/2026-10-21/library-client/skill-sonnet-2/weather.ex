defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when a request to the weather API fails.

  The `:type` field is one of:

    * `:api_error` - the API answered with a 4xx or 5xx status. `:status` is set.
    * `:unexpected_status` - the API answered with a status this client does not handle.
    * `:invalid_response` - the API answered 200 but the body was not a forecast.
    * `:transport_error` - the request did not complete (timeout, connection refused, ...).
  """

  @type type :: :api_error | :unexpected_status | :invalid_response | :transport_error

  @type t :: %__MODULE__{
          type: type(),
          status: non_neg_integer() | nil,
          message: String.t()
        }

  defexception [:type, :status, :message]
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
  Client for the weather HTTP API.

  Build a client once with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.temperature_c
      #=> 21.5

  Nothing is read from the application environment, so one application can
  hold several clients with different keys or base URLs.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_receive_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :receive_timeout, :req_options]
  defstruct [:api_key, :base_url, :receive_timeout, :req_options]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: timeout(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header of every request.
    * `:base_url` - base URL of the API. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for the response. Defaults to
      `#{@default_receive_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `[retry: false]` or `[plug: {Req.Test, WeatherClient}]` in tests.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", base_url: "http://localhost:4000")
      iex> client.base_url
      "http://localhost:4000"
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        receive_timeout: @default_receive_timeout,
        req_options: []
      ])

    %__MODULE__{
      api_key: fetch_api_key!(opts),
      base_url: opts[:base_url],
      receive_timeout: opts[:receive_timeout],
      req_options: opts[:req_options]
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:error, %WeatherClient.Error{}}` when the request fails.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> build_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp fetch_api_key!(opts) do
    case opts[:api_key] do
      api_key when is_binary(api_key) and api_key != "" ->
        api_key

      other ->
        raise ArgumentError, ":api_key must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp build_request(%__MODULE__{} = client) do
    [
      base_url: client.base_url,
      receive_timeout: client.receive_timeout,
      headers: [{"x-api-key", client.api_key}]
    ]
    |> Keyword.merge(client.req_options)
    |> Req.new()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: parse_forecast(body)

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when status >= 400 and is_binary(message) do
    {:error, %Error{type: :api_error, status: status, message: message}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error,
     %Error{
       type: :unexpected_status,
       status: status,
       message: "unexpected response status #{status}"
     }}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{type: :transport_error, message: Exception.message(exception)}}
  end

  defp parse_forecast(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(body) do
    {:error,
     %Error{
       type: :invalid_response,
       status: 200,
       message: "response body is not a forecast: #{inspect(body)}"
     }}
  end
end

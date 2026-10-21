defmodule WeatherClient.Error do
  @moduledoc """
  The reason returned in `{:error, reason}` when a request fails.

  `:reason` is one of:

    * `:api_error` - the API answered with a 4xx or 5xx status. `:status` holds the
      status code and `:message` holds the API's `"error"` text when it sent one.
    * `:invalid_response` - the API answered 2xx but the body is not a forecast.
    * `:transport` - no response arrived (connection refused, timeout, and so on).
  """

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :transport,
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
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  Build a client once with `new/2`, then pass it to `fetch_forecast/3`.

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, forecast} = WeatherClient.fetch_forecast(client, 52.52, 13.41)
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

    * `:base_url` - base URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - time in milliseconds to wait for a response. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options merged into every `Req` request, for example
      `[retry: false]` or `[plug: {Req.Test, WeatherClient}]` in tests. Defaults to `[]`.

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
    with {:ok, body} <- get(client, "/forecast", lat: lat, lon: lon) do
      parse_forecast(body)
    end
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

  defp get(client, path, params) do
    request =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    request
    |> Req.merge(client.req_options)
    |> Req.get(url: path, params: params)
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :api_error, status: status, message: error_message(status, body)}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :transport, message: Exception.message(exception)}}
  end

  defp error_message(_status, %{"error" => message}) when is_binary(message), do: message
  defp error_message(status, _body), do: "request failed with status #{status}"

  defp parse_forecast(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(_body) do
    {:error, %Error{reason: :invalid_response, message: "response is not a valid forecast"}}
  end
end

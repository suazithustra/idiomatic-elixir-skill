defmodule WeatherClient.Error do
  @moduledoc """
  Reason returned in `{:error, error}` by `WeatherClient` functions.

  ## Fields

    * `:type` - `:api` when the service answered with a non-2xx status,
      `:transport` when no response arrived (timeout, connection refused),
      `:invalid_response` when a 2xx body does not have the expected shape.
    * `:status` - the HTTP status for `:api` errors, otherwise `nil`.
    * `:reason` - the underlying exception for `:transport` errors, otherwise `nil`.
    * `:message` - a human-readable description.
  """

  defexception [:type, :status, :reason, :message]

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          reason: Exception.t() | nil,
          message: String.t()
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast for one location.
  """

  alias WeatherClient.Error

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc """
  Builds a forecast from the decoded JSON body of `GET /forecast`.

  ## Examples

      iex> body = %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12}
      iex> WeatherClient.Forecast.parse(body)
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

      iex> {:error, error} = WeatherClient.Forecast.parse(%{"condition" => "cloudy"})
      iex> error.type
      :invalid_response
  """
  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def parse(_body) do
    {:error, %Error{type: :invalid_response, message: "unexpected forecast response body"}}
  end
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API, built on `Req`.

  Create a client once with `new/2`, then pass it to `fetch_forecast/3`:

      client = WeatherClient.new("my-api-key", receive_timeout: 5_000)
      {:ok, forecast} = WeatherClient.fetch_forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_receive_timeout :timer.seconds(15)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :receive_timeout, :req_options]
  defstruct [:api_key, :base_url, :receive_timeout, :req_options]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:base_url` - base URL of the API. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for the response.
      Defaults to `#{@default_receive_timeout}`.
    * `:req_options` - extra options merged into the `Req` request, for
      example `[retry: false]` or `[plug: {Req.Test, WeatherClient}]` in tests.
      Defaults to `[]`.

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
        receive_timeout: @default_receive_timeout,
        req_options: []
      )

    build(api_key, opts[:base_url], opts[:receive_timeout], opts[:req_options])
  end

  @doc """
  Fetches the forecast for a latitude and longitude, in degrees.

  Returns `{:error, %WeatherClient.Error{}}` when the service answers with an
  error status, when the request fails, or when the body is not a forecast.
  """
  @spec fetch_forecast(t(), number(), number()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def fetch_forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    with {:ok, response} <- get_forecast(client, lat, lon),
         {:ok, body} <- check_status(response) do
      Forecast.parse(body)
    end
  end

  @doc """
  Like `fetch_forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec fetch_forecast!(t(), number(), number()) :: Forecast.t()
  def fetch_forecast!(%__MODULE__{} = client, lat, lon) do
    case fetch_forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build(api_key, base_url, receive_timeout, req_options)
       when is_binary(base_url) and is_integer(receive_timeout) and receive_timeout > 0 and
              is_list(req_options) do
    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      receive_timeout: receive_timeout,
      req_options: req_options
    }
  end

  defp get_forecast(client, lat, lon) do
    req =
      Req.new(
        base_url: client.base_url,
        receive_timeout: client.receive_timeout,
        headers: [{"x-api-key", client.api_key}]
      )

    req = Req.merge(req, client.req_options)

    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, exception} ->
        error = %Error{
          type: :transport,
          reason: exception,
          message: Exception.message(exception)
        }

        {:error, error}
    end
  end

  defp check_status(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, body}
  end

  defp check_status(%Req.Response{status: status, body: %{"error" => message}})
       when is_binary(message) do
    {:error, %Error{type: :api, status: status, message: message}}
  end

  defp check_status(%Req.Response{status: status}) do
    {:error, %Error{type: :api, status: status, message: "unexpected status #{status}"}}
  end
end

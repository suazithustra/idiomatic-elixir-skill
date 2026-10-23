defmodule WeatherClient.Error do
  @moduledoc """
  The reason in an `{:error, reason}` returned by `WeatherClient`.

  The `:reason` field is one of:

    * `:api` - the API answered with a non-2xx status. `:status` holds the status
      and `:details` the message from the `{"error": "..."}` body, or the raw body
      when it has another shape.
    * `:transport` - the request never got a response. `:details` holds the
      exception from Req, such as a `Req.TransportError`.
    * `:invalid_response` - the API answered 2xx with a body that is not a
      forecast. `:details` holds the body.
  """

  defexception [:reason, :status, :details]

  @type t :: %__MODULE__{
          reason: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          details: term()
        }

  @impl true
  def message(%__MODULE__{reason: :api, status: status, details: details})
      when is_binary(details) do
    "weather API returned status #{status}: #{details}"
  end

  def message(%__MODULE__{reason: :api, status: status, details: details}) do
    "weather API returned status #{status}: #{inspect(details)}"
  end

  def message(%__MODULE__{reason: :transport, details: details}) do
    "request to the weather API failed: #{Exception.message(details)}"
  end

  def message(%__MODULE__{reason: :invalid_response, details: details}) do
    "weather API returned an unexpected body: #{inspect(details)}"
  end
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
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def parse(body), do: {:error, %Error{reason: :invalid_response, details: body}}
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client once with `new/2`, then pass it to `forecast/3`. Nothing is read
  from the application environment, so several clients with different keys, base
  URLs, or timeouts can live side by side.

      client = WeatherClient.new("my-api-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_receive_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :receive_timeout]
  defstruct [:api_key, :base_url, :receive_timeout, req_options: []]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: timeout(),
          req_options: keyword()
        }

  @doc """
  Builds a client that authenticates with `api_key`.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for the response, a positive
      integer or `:infinity`. Defaults to `#{@default_receive_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `[retry: false]` or `[plug: {Req.Test, WeatherClient}]` in tests. They
      override the options built from the ones above.

  ## Examples

      iex> client = WeatherClient.new("secret", base_url: "http://localhost:4000")
      iex> client.base_url
      "http://localhost:4000"
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        receive_timeout: @default_receive_timeout,
        req_options: []
      )

    %__MODULE__{
      api_key: api_key,
      base_url: validate_base_url(opts[:base_url]),
      receive_timeout: validate_timeout(opts[:receive_timeout]),
      req_options: validate_req_options(opts[:req_options])
    }
  end

  @doc """
  Fetches the forecast for a latitude and longitude, in degrees.

  Returns `{:error, %WeatherClient.Error{}}` when the API answers with an error
  status, when the request fails, or when the response is not a forecast.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    with {:ok, body} <- get_forecast(client, lat, lon) do
      Forecast.parse(body)
    end
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

  defp get_forecast(client, lat, lon) do
    request = build_request(client)

    case Req.get(request, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{reason: :api, status: status, details: error_message(body)}}

      {:error, exception} ->
        {:error, %Error{reason: :transport, details: exception}}
    end
  end

  defp build_request(client) do
    options = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.receive_timeout
    ]

    Req.new(Keyword.merge(options, client.req_options))
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(body), do: body

  defp validate_base_url(base_url) when is_binary(base_url), do: base_url

  defp validate_timeout(:infinity), do: :infinity
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_req_options(req_options) when is_list(req_options), do: req_options
end

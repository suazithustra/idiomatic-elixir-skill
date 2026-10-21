defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API.

  Build a client once with `new/2`, then pass it to `forecast/3`. Nothing is
  read from the application environment, so one node can hold several clients
  with different keys, base URLs, or timeouts.

  ## Examples

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.40)
      forecast.temperature_c
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
          timeout: timeout(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:base_url` - base URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `[retry: false]` or `[plug: {Req.Test, MyStub}]`. Defaults to `[]`.

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

    base_url = Keyword.fetch!(opts, :base_url)
    timeout = Keyword.fetch!(opts, :timeout)
    req_options = Keyword.fetch!(opts, :req_options)

    validate_option!(:base_url, is_binary(base_url), base_url)
    validate_option!(:timeout, valid_timeout?(timeout), timeout)
    validate_option!(:req_options, Keyword.keyword?(req_options), req_options)

    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout, req_options: req_options}
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the API answers with an error, the response has an unexpected shape, or
  the request fails.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    request =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    request = Req.merge(request, client.req_options)

    case Req.get(request, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, response} -> handle_response(response)
      {:error, exception} -> {:error, Error.exception(type: :request_failed, reason: exception)}
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

  defp handle_response(%Req.Response{status: 200, body: body}), do: Forecast.parse(body)

  defp handle_response(%Req.Response{status: status, body: body}) when status in 400..599 do
    {:error, Error.exception(type: :api_error, status: status, reason: api_message(body))}
  end

  defp handle_response(%Req.Response{status: status}) do
    {:error, Error.exception(type: :unexpected_status, status: status)}
  end

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: nil

  defp valid_timeout?(timeout), do: timeout == :infinity or (is_integer(timeout) and timeout > 0)

  defp validate_option!(_key, true, _value), do: :ok

  defp validate_option!(key, false, value) do
    raise ArgumentError, "invalid value for option #{inspect(key)}: #{inspect(value)}"
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by the weather API.

  `condition` is kept as the string the API sent, because the API may add new
  conditions at any time.
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

  def parse(body) do
    {:error, Error.exception(type: :invalid_response, reason: body)}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` functions.

  The `:type` field says what went wrong:

    * `:api_error` - the API answered 4xx or 5xx. `:status` is the HTTP status
      and `:reason` is the API's error message, or `nil` if the body had none.
    * `:unexpected_status` - the API answered with a status that is neither 200
      nor an error. `:status` is set.
    * `:invalid_response` - a 200 response whose body is not a forecast.
      `:reason` is the decoded body.
    * `:request_failed` - the request never got a response, for example a
      timeout or a refused connection. `:reason` is the exception from Req.
  """

  @type type :: :api_error | :unexpected_status | :invalid_response | :request_failed

  @type t :: %__MODULE__{
          type: type(),
          status: pos_integer() | nil,
          reason: term()
        }

  defexception [:type, :status, :reason]

  @impl true
  def message(%__MODULE__{type: :api_error, status: status, reason: nil}) do
    "weather API returned status #{status}"
  end

  def message(%__MODULE__{type: :api_error, status: status, reason: message}) do
    "weather API returned status #{status}: #{message}"
  end

  def message(%__MODULE__{type: :unexpected_status, status: status}) do
    "weather API returned unexpected status #{status}"
  end

  def message(%__MODULE__{type: :invalid_response, reason: body}) do
    "weather API returned a body that is not a forecast: #{inspect(body)}"
  end

  def message(%__MODULE__{type: :request_failed, reason: exception})
      when is_exception(exception) do
    "weather API request failed: #{Exception.message(exception)}"
  end
end

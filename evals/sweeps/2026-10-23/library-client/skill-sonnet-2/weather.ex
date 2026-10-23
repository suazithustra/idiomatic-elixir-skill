defmodule WeatherClient.Error do
  @moduledoc """
  The error returned when a request to the weather API fails.

  `:reason` is one of:

    * `:api` - the API answered with a 4xx or 5xx status. `:status` holds the
      status and `:detail` the message from the response's `"error"` field.
    * `:transport` - the request never got a response (timeout, connection
      refused, and so on). `:detail` holds the underlying exception.
    * `:invalid_response` - the API answered, but the status or body is not
      what the API documents. `:status` holds the status and `:detail` the body.
  """

  @type reason :: :api | :transport | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          status: non_neg_integer() | nil,
          detail: term()
        }

  defexception [:reason, :status, :detail]

  @impl true
  def message(%__MODULE__{reason: :api} = error) do
    "weather API returned #{error.status}: #{error.detail}"
  end

  def message(%__MODULE__{reason: :transport} = error) do
    "weather API request failed: #{Exception.message(error.detail)}"
  end

  def message(%__MODULE__{reason: :invalid_response} = error) do
    "weather API returned an unexpected response (status #{error.status}): " <>
      inspect(error.detail)
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast as returned by `WeatherClient.forecast/3`.
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
  A client for the weather HTTP API.

  Build a client once with `new/2`, then pass it to `forecast/3`:

      client = WeatherClient.new("my-api-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  A client holds no processes and no global state, so a program can use several
  clients with different keys, base URLs, or timeouts at the same time.
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
          timeout: pos_integer()
        }

  @doc """
  Builds a client for the given API key.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for the response, in milliseconds.
      Defaults to `#{@default_timeout}`.

  ## Examples

      iex> client = WeatherClient.new("secret", timeout: 2_000)
      iex> client.timeout
      2000
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) do
    opts = Keyword.validate!(opts, base_url: @default_base_url, timeout: @default_timeout)

    build_client(api_key, opts[:base_url], opts[:timeout])
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the API reports an error, the request fails, or the response is malformed.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    request =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    case Req.get(request, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{} = response} -> parse_response(response)
      {:error, exception} -> {:error, %Error{reason: :transport, detail: exception}}
    end
  end

  @doc """
  Like `forecast/3`, but returns the forecast or raises a `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build_client(api_key, base_url, timeout)
       when is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout}
  end

  defp parse_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    parse_forecast(status, body)
  end

  defp parse_response(%Req.Response{status: status, body: %{"error" => message}})
       when status >= 400 do
    {:error, %Error{reason: :api, status: status, detail: message}}
  end

  defp parse_response(%Req.Response{status: status, body: body}) do
    {:error, %Error{reason: :invalid_response, status: status, detail: body}}
  end

  defp parse_forecast(_status, %{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(status, body) do
    {:error, %Error{reason: :invalid_response, status: status, detail: body}}
  end
end

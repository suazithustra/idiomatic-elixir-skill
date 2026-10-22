defmodule WeatherClient do
  @moduledoc """
  A client for the public weather HTTP API, built on `Req`.

  Configuration is passed to `new/2`, so several clients with different keys,
  base URLs or timeouts can live in the same system.

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
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
  Builds a client that authenticates with `api_key`.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options merged into the `Req` request, such as
      `:retry` or `:plug`. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", timeout: 2_000)
      iex> client.timeout
      2000
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

  Returns `{:error, %WeatherClient.Error{}}` when the API answers with an error
  status, the request fails, or the response body has an unexpected shape.
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
  Same as `forecast/3`, but returns the forecast or raises a `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp get_forecast(client, lat, lon) do
    request = Req.new(request_options(client))

    case Req.get(request, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{reason: :api_error, status: status, detail: body}}

      {:error, exception} ->
        {:error, %Error{reason: :request_failed, detail: exception}}
    end
  end

  defp request_options(client) do
    defaults = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]

    Keyword.merge(defaults, client.req_options)
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by the weather API.
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

  def parse(body), do: {:error, %Error{reason: :invalid_response, detail: body}}
end

defmodule WeatherClient.Error do
  @moduledoc """
  The reason of a failed `WeatherClient` call.

  `:reason` is one of:

    * `:api_error` - the API answered with a non-2xx `:status`; `:detail` is the
      decoded response body.
    * `:request_failed` - no response arrived; `:detail` is the exception from `Req`.
    * `:invalid_response` - the API answered 2xx with a body of an unexpected
      shape; `:detail` is that body.
  """

  defexception [:reason, :status, :detail]

  @type t :: %__MODULE__{
          reason: :api_error | :request_failed | :invalid_response,
          status: pos_integer() | nil,
          detail: term()
        }

  @impl Exception
  def message(%__MODULE__{reason: :api_error, status: status, detail: %{"error" => error}})
      when is_binary(error) do
    "weather API returned status #{status}: #{error}"
  end

  def message(%__MODULE__{reason: :api_error, status: status}) do
    "weather API returned status #{status}"
  end

  def message(%__MODULE__{reason: :request_failed, detail: exception})
      when is_exception(exception) do
    "weather API request failed: #{Exception.message(exception)}"
  end

  def message(%__MODULE__{reason: :invalid_response, detail: body}) do
    "weather API returned an unexpected response: #{inspect(body)}"
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` when a request fails.

  `:type` says what went wrong:

    * `:api_error` - the API answered with a 4xx or 5xx status. `:status` holds
      the status code and `:message` the API's `"error"` text, if it sent one.
    * `:unexpected_status` - the API answered with a status outside 200 and
      400-599. `:status` holds it.
    * `:invalid_response` - the API answered 200 but the body was not a forecast.
    * `:transport` - no response arrived (timeout, connection refused, DNS
      failure). `:message` holds the underlying exception's message.
  """

  @type type :: :api_error | :unexpected_status | :invalid_response | :transport

  @type t :: %__MODULE__{
          type: type(),
          status: non_neg_integer() | nil,
          message: String.t() | nil
        }

  defexception [:type, :status, :message]

  @impl true
  def message(%__MODULE__{type: :api_error, status: status, message: nil}) do
    "weather API returned status #{status}"
  end

  def message(%__MODULE__{type: :api_error, status: status, message: message}) do
    "weather API returned status #{status}: #{message}"
  end

  def message(%__MODULE__{type: :unexpected_status, status: status}) do
    "weather API returned unexpected status #{status}"
  end

  def message(%__MODULE__{type: :invalid_response}) do
    "weather API returned a body that is not a forecast"
  end

  def message(%__MODULE__{type: :transport, message: message}) do
    "request to weather API failed: #{message}"
  end
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

  Build a client once with `new/2`, then pass it to `fetch_forecast/3`:

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, forecast} = WeatherClient.fetch_forecast(client, 52.52, 13.405)

  The client holds no processes and reads no application environment, so you
  can create as many differently configured clients as you need.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder: replace with the API's real production URL before publishing.
  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  defstruct [:api_key, :base_url, :timeout, :req_options]

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
    * `:timeout` - how long to wait for the response, in milliseconds, as a
      positive integer or `:infinity`. Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `plug:` to stub the API in tests. They override the options set by
      this client. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", timeout: 2_000)
      iex> client.timeout
      2000
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" and is_list(opts) do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    %__MODULE__{
      api_key: api_key,
      base_url: check_base_url(opts[:base_url]),
      timeout: check_timeout(opts[:timeout]),
      req_options: check_req_options(opts[:req_options])
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude, in degrees.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec fetch_forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def fetch_forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    request =
      Req.new(
        Keyword.merge(
          [
            base_url: client.base_url,
            headers: [{"x-api-key", client.api_key}],
            receive_timeout: client.timeout
          ],
          client.req_options
        )
      )

    case Req.get(request, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{} = response} -> parse_response(response)
      {:error, exception} -> {:error, transport_error(exception)}
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

  defp parse_response(%Req.Response{status: 200, body: body}), do: parse_forecast(body)

  defp parse_response(%Req.Response{status: status, body: body}) when status in 400..599 do
    {:error, %Error{type: :api_error, status: status, message: error_text(body)}}
  end

  defp parse_response(%Req.Response{status: status}) do
    {:error, %Error{type: :unexpected_status, status: status}}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(_body), do: {:error, %Error{type: :invalid_response, status: 200}}

  defp error_text(%{"error" => message}) when is_binary(message), do: message
  defp error_text(_body), do: nil

  defp transport_error(exception) do
    %Error{type: :transport, message: Exception.message(exception)}
  end

  defp check_base_url(base_url) when is_binary(base_url) and base_url != "", do: base_url

  defp check_base_url(other) do
    raise ArgumentError, ":base_url must be a non-empty string, got: #{inspect(other)}"
  end

  defp check_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp check_timeout(:infinity), do: :infinity

  defp check_timeout(other) do
    raise ArgumentError,
          ":timeout must be a positive integer or :infinity, got: #{inspect(other)}"
  end

  defp check_req_options(req_options) when is_list(req_options), do: req_options

  defp check_req_options(other) do
    raise ArgumentError, ":req_options must be a keyword list, got: #{inspect(other)}"
  end
end

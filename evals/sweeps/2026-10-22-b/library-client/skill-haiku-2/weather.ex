defmodule WeatherClient.Error do
  @moduledoc """
  An error from the weather API, from the HTTP transport, or from a response
  that does not have the forecast fields.

  `kind` is one of:

    * `:api` - the API answered with a 4xx or 5xx status. `status` holds it and
      `detail` holds the `"error"` message from the body, or `nil`.
    * `:transport` - no response arrived. `detail` holds the exception Req returned.
    * `:invalid_response` - a 2xx body without the expected fields. `detail`
      holds the body.
  """

  @type t :: %__MODULE__{
          kind: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          detail: term()
        }

  defexception [:kind, :status, :detail]

  @impl true
  def message(%__MODULE__{kind: :api, status: status, detail: detail}) do
    "weather API returned HTTP #{status}: #{detail || "no details"}"
  end

  def message(%__MODULE__{kind: :transport, detail: exception}) do
    "request failed: #{Exception.message(exception)}"
  end

  def message(%__MODULE__{kind: :invalid_response, detail: body}) do
    "unexpected response body: #{inspect(body)}"
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  The current forecast for one location, as returned by `WeatherClient.forecast/3`.
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
  Client for the weather forecast API.

  Build a client once with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 51.5, -0.12)
      forecast.temperature_c
  """

  alias WeatherClient.{Error, Forecast}

  # Override with `base_url:` in `new/1` to use another host or a test server.
  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct [:api_key, base_url: @default_base_url, timeout: @default_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  defguardp is_latitude(lat) when is_number(lat) and lat >= -90 and lat <= 90
  defguardp is_longitude(lon) when is_number(lon) and lon >= -180 and lon <= 180

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - milliseconds to wait for each attempt. Defaults to `#{@default_timeout}`.

  Raises `KeyError` when `:api_key` is missing, and `ArgumentError` for an
  unknown option or an invalid value.

  ## Examples

      iex> client = WeatherClient.new(api_key: "test-key", timeout: 1_000)
      iex> client.timeout
      1000
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [:api_key, base_url: @default_base_url, timeout: @default_timeout])

    build(Keyword.fetch!(opts, :api_key), opts[:base_url], opts[:timeout])
  end

  @doc """
  Fetches the current forecast at a latitude and longitude in decimal degrees.

  Returns `{:error, %WeatherClient.Error{}}` for API, transport, and malformed
  response failures. `:timeout` applies to each attempt; Req retries transient
  failures by default.

  ## Examples

      {:ok, %WeatherClient.Forecast{condition: "cloudy"}} =
        WeatherClient.forecast(client, 51.5, -0.12)
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_latitude(lat) and is_longitude(lon) do
    client
    |> http_client()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  defp build(api_key, base_url, timeout)
       when is_binary(api_key) and is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout}
  end

  defp http_client(%__MODULE__{} = client) do
    Req.new(
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    )
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    decode_forecast(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status >= 400 do
    {:error, %Error{kind: :api, status: status, detail: error_message(body)}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{kind: :transport, detail: exception}}
  end

  defp decode_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp decode_forecast(body), do: {:error, %Error{kind: :invalid_response, detail: body}}

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil
end

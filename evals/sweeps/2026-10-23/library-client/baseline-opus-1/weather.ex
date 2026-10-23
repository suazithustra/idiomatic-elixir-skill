defmodule WeatherClient.Forecast do
  @moduledoc """
  The forecast for one location.

  `:condition` is the string the API sends, such as `"cloudy"`. It is not turned into
  an atom, because the API, not this library, decides which conditions exist.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  Returned by `WeatherClient.forecast/3` and raised by `WeatherClient.forecast!/3`.

  `:reason` says what went wrong:

    * `:http_error` - the API answered with a non-2xx status. `:status` holds the
      status code, `:api_message` the API's `"error"` string if it sent one, and
      `:body` the response body.

    * `:invalid_response` - the API answered with a 2xx status, but the body was not
      a forecast. `:status` and `:body` hold what was received.

    * `:transport_error` - no response arrived, for example because of a timeout or a
      refused connection. `:exception` holds the underlying exception.
  """

  defexception [:reason, :status, :api_message, :body, :exception]

  @type t :: %__MODULE__{
          reason: :http_error | :invalid_response | :transport_error,
          status: pos_integer() | nil,
          api_message: String.t() | nil,
          body: term(),
          exception: Exception.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :http_error, status: status, api_message: nil}) do
    "weather API returned HTTP #{status}"
  end

  def message(%__MODULE__{reason: :http_error, status: status, api_message: api_message}) do
    "weather API returned HTTP #{status}: #{api_message}"
  end

  def message(%__MODULE__{reason: :invalid_response, status: status, body: body}) do
    "weather API returned HTTP #{status} with an unexpected body: #{inspect(body)}"
  end

  def message(%__MODULE__{reason: :transport_error, exception: exception}) do
    "weather API request failed: #{Exception.message(exception)}"
  end
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Build a client once with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy"}} =
        WeatherClient.forecast(client, 52.52, 13.41)

  The client is a plain struct. This library does not read application config, so
  build the client from your own configuration and keep it wherever suits your app.

  ## Testing

  Pass a `Req.Test` plug through `:req_options` to stub the API. Turning retries off
  keeps tests of error responses fast:

      client =
        WeatherClient.new(
          api_key: "test-key",
          req_options: [plug: {Req.Test, WeatherClient}, retry: false]
        )

      Req.Test.stub(WeatherClient, fn conn ->
        Req.Test.json(conn, %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12})
      end)

      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder: replace with the API's production base URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout 15_000

  @defaults [base_url: @default_base_url, timeout: @default_timeout, req_options: []]

  @enforce_keys [:req, :api_key]
  @derive {Inspect, except: [:api_key]}
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{req: Req.Request.t(), api_key: String.t()}

  @type option ::
          {:api_key, String.t()}
          | {:base_url, String.t()}
          | {:timeout, timeout()}
          | {:req_options, keyword()}

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent with every request in the `x-api-key` header.

    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.

    * `:timeout` - how long to wait for a response, in milliseconds, or `:infinity`.
      Defaults to `#{@default_timeout}`.

    * `:req_options` - extra options for `Req.new/1`, applied after the options above
      so they take precedence. Useful for `:plug` in tests or `:retry` to change
      Req's retry behaviour. Defaults to `[]`.

  Raises `ArgumentError` if an option is missing, unknown or invalid.
  """
  @spec new([option()]) :: t()
  def new(opts) when is_list(opts) do
    opts = validate_keys!(opts)

    api_key = validate_api_key!(Keyword.get(opts, :api_key))
    base_url = fetch_option!(opts, :base_url, &is_binary/1, "a string")
    timeout = fetch_option!(opts, :timeout, &valid_timeout?/1, "a non-negative integer or :infinity")
    req_options = fetch_option!(opts, :req_options, &Keyword.keyword?/1, "a keyword list")

    req =
      [base_url: base_url, receive_timeout: timeout]
      |> Req.new()
      |> Req.merge(req_options)

    %__MODULE__{req: req, api_key: api_key}
  end

  @doc """
  Fetches the forecast for a latitude and longitude.

  Returns `{:ok, forecast}` or `{:error, error}`. See `WeatherClient.Error` for the
  kinds of error.

  Req retries timeouts and 408, 429 and 5xx responses up to three times before this
  function returns an error. Pass `req_options: [retry: false]` to `new/1` to turn
  that off.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client.req
    |> Req.get(
      url: "/forecast",
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", client.api_key}]
    )
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    parse_forecast(status, body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :http_error, status: status, api_message: api_message(body), body: body}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :transport_error, exception: exception}}
  end

  defp parse_forecast(
         _status,
         %{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph}
       )
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(status, body) do
    {:error, %Error{reason: :invalid_response, status: status, body: body}}
  end

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: nil

  # Keyword.validate!/2 would put every option, the API key included, in its error
  # message, so unknown keys are reported by hand.
  defp validate_keys!(opts) do
    case Keyword.validate(opts, [:api_key | @defaults]) do
      {:ok, opts} ->
        opts

      {:error, unknown} ->
        raise ArgumentError,
              "unknown options #{inspect(unknown)}, " <>
                "expected one of: #{inspect([:api_key | Keyword.keys(@defaults)])}"
    end
  end

  defp validate_api_key!(api_key) when is_binary(api_key) and api_key != "", do: api_key

  # The value is left out of the message so a misconfigured key does not reach logs.
  defp validate_api_key!(_api_key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp fetch_option!(opts, key, valid?, expected) do
    value = Keyword.fetch!(opts, key)

    if valid?.(value) do
      value
    else
      raise ArgumentError, "expected #{inspect(key)} to be #{expected}, got: #{inspect(value)}"
    end
  end

  defp valid_timeout?(:infinity), do: true
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 0
end

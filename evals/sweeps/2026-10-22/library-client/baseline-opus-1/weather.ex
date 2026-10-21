# Forecast and Error are defined first because WeatherClient builds their
# structs, and a struct must be compiled before it can be used in the same file.

defmodule WeatherClient.Forecast do
  @moduledoc """
  Current weather for a location, as returned by `WeatherClient.forecast/3`.

  `:condition` is the string the API sends, such as `"cloudy"`.
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
  A failed request.

  Returned as `{:error, %WeatherClient.Error{}}` by `WeatherClient.forecast/3`
  and raised by `WeatherClient.forecast!/3`.

  The `:reason` field says what went wrong:

    * `:http_error` - the API responded with a non-2xx status. `:status` holds
      the status code, and `:message` includes the API's `"error"` text when
      the body has one.

    * `:invalid_response` - the API responded with a 2xx status but the body
      did not have the expected shape. `:body` holds what was received.

    * an exception, such as `%Req.TransportError{reason: :timeout}` - the
      request did not complete (timeout, connection refused, DNS failure).
  """

  defexception [:message, :reason, :status, :body]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: :http_error | :invalid_response | Exception.t(),
          status: non_neg_integer() | nil,
          body: term()
        }
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  Build a client once with `new/1` and pass it to the request functions:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))

      case WeatherClient.forecast(client, 52.52, 13.41) do
        {:ok, %WeatherClient.Forecast{temperature_c: temp, condition: condition}} ->
          IO.puts("\#{temp} °C, \#{condition}")

        {:error, %WeatherClient.Error{reason: :http_error, status: 401}} ->
          IO.puts("check your API key")

        {:error, error} ->
          IO.puts(Exception.message(error))
      end

  This library does not read application config. Keep the API key and other
  settings wherever suits your application and pass them to `new/1`.

  ## Testing

  `:req_options` accepts any `Req.new/1` option, including `:plug`, so you can
  stub the API with `Req.Test`:

      client =
        WeatherClient.new(
          api_key: "test",
          req_options: [plug: {Req.Test, WeatherClient}, retry: false]
        )

      Req.Test.stub(WeatherClient, fn conn ->
        Req.Test.json(conn, %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12})
      end)
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder host. Replace with the real API's base URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout 15_000

  @enforce_keys [:req, :api_key]
  @derive {Inspect, except: [:api_key]}
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{req: Req.Request.t(), api_key: String.t()}

  @doc """
  Builds a client.

  ## Options

    * `:api_key` (required) - sent in the `x-api-key` header on every request.

    * `:base_url` - root URL of the API. Defaults to `#{inspect(@default_base_url)}`.

    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.

    * `:req_options` - extra options passed to `Req.new/1`, such as
      `retry: false` or `connect_options: [timeout: 5_000]`. These are applied
      last, so they override the options above.

  The API key is kept out of `inspect/1` output so it does not end up in logs.

  Raises `ArgumentError` if an option is missing, unknown, or invalid.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      ])

    api_key = validate_option!(:api_key, opts[:api_key])
    base_url = validate_option!(:base_url, opts[:base_url])
    timeout = validate_option!(:timeout, opts[:timeout])
    req_options = validate_option!(:req_options, opts[:req_options])

    req =
      [base_url: base_url, receive_timeout: timeout]
      |> Req.new()
      |> Req.merge(req_options)

    %__MODULE__{req: req, api_key: api_key}
  end

  @doc """
  Fetches the current weather at the given latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  if the API returns an error status or an unexpected body, or the request
  fails. See `WeatherClient.Error` for the possible reasons.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, response} <- get(client, "/forecast", lat: lat, lon: lon) do
      parse_forecast(response)
    end
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

  defp get(%__MODULE__{req: req, api_key: api_key}, path, params) do
    case Req.get(req, url: path, params: params, headers: [{"x-api-key", api_key}]) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         %Error{
           reason: :http_error,
           status: status,
           body: body,
           message: http_error_message(status, body)
         }}

      {:error, exception} ->
        {:error,
         %Error{
           reason: exception,
           message: "request to weather API failed: " <> Exception.message(exception)
         }}
    end
  end

  defp http_error_message(status, %{"error" => message}) when is_binary(message) do
    "weather API responded with HTTP #{status}: #{message}"
  end

  defp http_error_message(status, _body) do
    "weather API responded with HTTP #{status}"
  end

  defp parse_forecast(%Req.Response{
         body: %{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind}
       })
       when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(%Req.Response{status: status, body: body}) do
    {:error,
     %Error{
       reason: :invalid_response,
       status: status,
       body: body,
       message: "weather API returned an unexpected forecast body (HTTP #{status})"
     }}
  end

  defp validate_option!(:api_key, key) when is_binary(key) and byte_size(key) > 0, do: key

  defp validate_option!(:api_key, nil) do
    raise ArgumentError, "the :api_key option is required"
  end

  # The value is left out of this message so a malformed key is not printed.
  defp validate_option!(:api_key, _key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp validate_option!(:base_url, url) when is_binary(url), do: url
  defp validate_option!(:timeout, ms) when is_integer(ms) and ms > 0, do: ms
  defp validate_option!(:req_options, opts) when is_list(opts), do: opts

  defp validate_option!(name, value) do
    raise ArgumentError, "invalid value for #{inspect(name)} option: #{inspect(value)}"
  end
end

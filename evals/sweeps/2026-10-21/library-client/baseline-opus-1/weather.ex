defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.

  `:condition` is the string the API sends, such as `"cloudy"`. It is not
  converted to an atom, so conditions the API adds later still work and
  untrusted input never creates atoms.
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
  The error returned by `WeatherClient.forecast/3` and raised by
  `WeatherClient.forecast!/3`.

  `:reason` says what went wrong:

    * `:api_error` - the API answered with a non-2xx status. `:status` holds the
      status code, `:api_message` the API's `"error"` text if it sent one, and
      `:body` the decoded body.

    * `:invalid_response` - the API answered, but the body was not a forecast or
      could not be decoded. `:body` holds what was received, if anything, and
      `:cause` the underlying exception, if any.

    * `:transport_error` - no response arrived, for example because of a timeout
      or a refused connection. `:cause` holds the `Req.TransportError`.
  """

  defexception [:reason, :status, :api_message, :body, :cause]

  @type reason :: :api_error | :invalid_response | :transport_error

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          api_message: String.t() | nil,
          body: term(),
          cause: Exception.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, status: status, api_message: nil}) do
    "weather API returned HTTP #{status}"
  end

  def message(%__MODULE__{reason: :api_error, status: status, api_message: api_message}) do
    "weather API returned HTTP #{status}: #{api_message}"
  end

  def message(%__MODULE__{reason: :invalid_response, cause: nil}) do
    "weather API returned a body that is not a forecast"
  end

  def message(%__MODULE__{reason: :invalid_response, cause: cause}) do
    "weather API returned an invalid response: " <> Exception.message(cause)
  end

  def message(%__MODULE__{reason: :transport_error, cause: cause}) do
    "could not reach weather API: " <> Exception.message(cause)
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather forecast HTTP API.

  Build a client with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))

      {:ok, forecast} = WeatherClient.forecast(client, 51.5072, -0.1276)
      forecast.temperature_c
      #=> 21.5

  ## Configuration

  This library reads no application config. Pass every setting to `new/1`,
  building the client at runtime from your own config (for example values set
  in `config/runtime.exs`), and hand it to each call.

  ## Retries

  Requests use Req's default retry behaviour: timeouts, connection errors and
  HTTP 408, 429, 500, 502, 503 and 504 responses are retried up to 3 times with
  exponential backoff. Pass `req_options: [retry: false]` to turn this off.

  ## Testing

  `:req_options` is passed to Req unchanged, so you can stub the API with
  `Req.Test`:

      client =
        WeatherClient.new(
          api_key: "test-key",
          req_options: [plug: {Req.Test, WeatherClient}, retry: false]
        )

      Req.Test.stub(WeatherClient, fn conn ->
        Req.Test.json(conn, %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12})
      end)

      {:ok, %WeatherClient.Forecast{condition: "cloudy"}} = WeatherClient.forecast(client, 0, 0)
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder host (reserved .example domain): set the real API URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  @derive {Inspect, except: [:api_key]}
  defstruct @enforce_keys

  @typedoc "A configured client. Build one with `new/1`."
  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer() | :infinity,
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` (required) - your API key, sent in the `x-api-key` header. It is
      hidden when the client is inspected or logged.

    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.

    * `:timeout` - how long to wait for data from the API, in milliseconds, or
      `:infinity`. Passed to Req as `:receive_timeout`. Defaults to
      `#{@default_timeout}`.

    * `:req_options` - extra options for `Req.new/1`, such as `:plug` for tests,
      `:retry` or `:connect_options`. These override the options above.

  Raises `ArgumentError` if an option is missing, unknown or invalid.

  ## Examples

      WeatherClient.new(api_key: "my-key", timeout: 10_000)

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

    %__MODULE__{
      api_key: api_key!(opts[:api_key]),
      base_url: base_url!(opts[:base_url]),
      timeout: timeout!(opts[:timeout]),
      req_options: req_options!(opts[:req_options])
    }
  end

  @doc """
  Fetches the forecast for a latitude and longitude, in decimal degrees.

  Returns `{:ok, forecast}` on success and `{:error, error}` otherwise. See
  `WeatherClient.Error` for the kinds of error.

  ## Examples

      WeatherClient.forecast(client, 51.5072, -0.1276)
      #=> {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

      WeatherClient.forecast(client_with_bad_key, 51.5072, -0.1276)
      #=> {:error, %WeatherClient.Error{reason: :api_error, status: 401, api_message: "invalid API key"}}

  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> new_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp new_request(client) do
    [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]
    |> Req.new()
    |> Req.merge(client.req_options)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    case body do
      %{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind}
      when is_number(temperature) and is_binary(condition) and is_number(wind) ->
        {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}

      _other ->
        {:error, %Error{reason: :invalid_response, status: status, body: body}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :api_error, status: status, api_message: api_message(body), body: body}}
  end

  defp handle_response({:error, %Req.TransportError{} = exception}) do
    {:error, %Error{reason: :transport_error, cause: exception}}
  end

  # Anything else Req returns means a response arrived but could not be used,
  # for example a body that failed to decode or too many redirects.
  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :invalid_response, cause: exception}}
  end

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: nil

  defp api_key!(key) when is_binary(key) and key != "", do: key

  # The value is left out of the message so a malformed key never reaches logs.
  defp api_key!(_key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp base_url!(url) when is_binary(url) and url != "", do: url

  defp base_url!(url) do
    raise ArgumentError, "expected :base_url to be a non-empty string, got: #{inspect(url)}"
  end

  defp timeout!(:infinity), do: :infinity
  defp timeout!(ms) when is_integer(ms) and ms > 0, do: ms

  defp timeout!(other) do
    raise ArgumentError,
          "expected :timeout to be a positive integer or :infinity, got: #{inspect(other)}"
  end

  defp req_options!(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "expected :req_options to be a keyword list, got: #{inspect(opts)}"
    end
  end
end

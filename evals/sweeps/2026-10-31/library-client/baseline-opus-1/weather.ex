defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  Returned by `WeatherClient.forecast/3` and raised by `WeatherClient.forecast!/3`.

  The `:reason` field says what went wrong:

    * `:api_error` - the API answered with a 4xx or 5xx status. `:status` holds
      the status code and `:message` includes the API's error text.

    * `:invalid_response` - the API answered, but not with a forecast, for
      example a success status with missing fields.

    * `:request_failed` - no usable response arrived, for example because of a
      timeout, a refused connection or a body that could not be decoded.
      `:cause` holds the underlying exception.

  To handle a timeout specifically, match on `:cause`:

      {:error, %WeatherClient.Error{cause: %Req.TransportError{reason: :timeout}}}
  """

  defexception [:reason, :status, :message, :cause]

  @type t :: %__MODULE__{
          __exception__: true,
          reason: :api_error | :invalid_response | :request_failed,
          status: non_neg_integer() | nil,
          message: String.t(),
          cause: Exception.t() | nil
        }
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather forecast HTTP API.

  Build a client with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))

      case WeatherClient.forecast(client, 52.52, 13.41) do
        {:ok, forecast} -> forecast.temperature_c
        {:error, error} -> Exception.message(error)
      end

  Configuration lives in the client, not in application config, so one
  application can hold several clients with different settings.

  ## Testing

  Use `:req_options` to route requests to a `Req.Test` stub:

      client = WeatherClient.new(api_key: "test", req_options: [plug: {Req.Test, MyStub}])

      Req.Test.stub(MyStub, fn conn ->
        Req.Test.json(conn, %{temperature_c: 21.5, condition: "cloudy", wind_kph: 12})
      end)
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder: set this to the real API host before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout 15_000

  @enforce_keys [:req]
  # The request holds the API key, and Req only redacts `authorization` headers.
  @derive {Inspect, except: [:req]}
  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.

    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.

    * `:timeout` - milliseconds to wait for a response, per attempt. Defaults
      to `#{@default_timeout}`.

    * `:req_options` - extra options merged into the underlying `Req` request.
      See `Req.new/1`. Defaults to `[]`.

  Req retries timeouts and temporary server errors up to three times by default,
  so a call can take longer than `:timeout`. To turn this off, pass
  `req_options: [retry: false]`.

  Raises `ArgumentError` if `:api_key` is not a non-empty string or an option is
  unknown, and `KeyError` if `:api_key` is missing.
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

    req =
      [
        base_url: opts[:base_url],
        headers: [{"x-api-key", fetch_api_key!(opts)}],
        receive_timeout: opts[:timeout],
        # On a redirect to another host, Req drops `authorization` headers but
        # would forward `x-api-key`.
        redirect: false
      ]
      |> Req.new()
      |> Req.merge(opts[:req_options])

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the forecast for a latitude and longitude.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} ->
        handle_response(status, body)

      {:error, exception} ->
        {:error,
         %Error{
           reason: :request_failed,
           message: Exception.message(exception),
           cause: exception
         }}
    end
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

  defp fetch_api_key!(opts) do
    case Keyword.fetch!(opts, :api_key) do
      key when is_binary(key) and key != "" -> key
      _other -> raise ArgumentError, "expected :api_key to be a non-empty string"
    end
  end

  defp handle_response(
         status,
         %{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph}
       )
       when status in 200..299 and is_number(temperature_c) and is_binary(condition) and
              is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp handle_response(status, %{"error" => message}) when status >= 400 and is_binary(message) do
    {:error, %Error{reason: :api_error, status: status, message: "HTTP #{status}: #{message}"}}
  end

  defp handle_response(status, _body) when status >= 400 do
    {:error, %Error{reason: :api_error, status: status, message: "HTTP #{status}"}}
  end

  defp handle_response(status, _body) do
    {:error,
     %Error{
       reason: :invalid_response,
       status: status,
       message: "unexpected response with HTTP status #{status}"
     }}
  end
end

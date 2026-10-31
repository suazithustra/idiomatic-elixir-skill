# Forecast and Error come first: WeatherClient uses their structs, and modules in one file
# compile from top to bottom.

defmodule WeatherClient.Forecast do
  @moduledoc """
  The forecast for one location.

  `:condition` is the API's text as received, for example `"cloudy"`. It stays a string because
  turning text from an external service into atoms can exhaust the atom table.
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
  The error returned by `WeatherClient.forecast/3` and raised by `WeatherClient.forecast!/3`.

  The `:reason` field says what went wrong:

    * `:api_error` - the API answered with a non-2xx status. `:status` holds the status and
      `:message` holds the API's `"error"` text, if the body had one.

    * `:unexpected_response` - the API answered with a 2xx status, but the body was not the
      expected forecast JSON. `:status` holds the status.

    * `:request_failed` - no usable response arrived, for example because of a timeout, a
      connection failure or a body that could not be decoded. `:cause` holds the underlying
      exception.
  """

  @type reason :: :api_error | :unexpected_response | :request_failed

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          status: pos_integer() | nil,
          cause: Exception.t() | nil
        }

  defexception [:reason, :message, :status, :cause]

  @impl true
  def message(%__MODULE__{status: nil, message: message}), do: message
  def message(%__MODULE__{status: status, message: message}), do: "HTTP #{status}: #{message}"
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

      client = WeatherClient.new("my-api-key")

      case WeatherClient.forecast(client, 52.52, 13.41) do
        {:ok, forecast} -> forecast.temperature_c
        {:error, error} -> Exception.message(error)
      end

  All configuration goes through `new/2`. The library reads no application environment, so an
  application can run several differently configured clients at once.

  ## Testing

  Use `:req_options` to route requests to a stub instead of the network:

      client = WeatherClient.new("test-key", req_options: [plug: {Req.Test, MyApp.Weather}])

      Req.Test.stub(MyApp.Weather, fn conn ->
        Req.Test.json(conn, %{temperature_c: 21.5, condition: "cloudy", wind_kph: 12})
      end)
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder host. Replace with the real API URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  # The Req request holds the API key in its headers, so it must stay out of logs.
  @derive {Inspect, except: [:req]}
  @enforce_keys [:req]
  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @type option ::
          {:base_url, String.t()}
          | {:timeout, timeout()}
          | {:req_options, keyword()}

  @doc """
  Builds a client that sends `api_key` with every request.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.

    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`.

    * `:req_options` - extra options for `Req.new/1`, applied after the ones above.

  Req retries GET requests after timeouts, connection errors and statuses 408, 429, 500, 502,
  503 and 504, up to 3 times with growing delays. `:timeout` applies to each attempt, so a
  failing call can take much longer than `:timeout`. To turn this off, pass
  `req_options: [retry: false]`.
  """
  @spec new(String.t(), [option()]) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    req =
      [
        base_url: opts[:base_url],
        headers: [{"x-api-key", api_key}],
        receive_timeout: opts[:timeout],
        # On a redirect to another host Req drops the `authorization` header but not custom
        # headers, so following one would send the API key to that host.
        redirect: false
      ]
      |> Req.new()
      |> Req.merge(opts[:req_options])

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the forecast for the given latitude and longitude.

  Returns `{:ok, forecast}` or `{:error, error}`. See `WeatherClient.Error` for the error cases.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    req
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly and raises `WeatherClient.Error` on
  failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp handle_response(
         {:ok,
          %Req.Response{
            status: 200,
            body: %{
              "temperature_c" => temperature_c,
              "condition" => condition,
              "wind_kph" => wind_kph
            }
          }}
       )
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) when status in 200..299 do
    {:error,
     %Error{
       reason: :unexpected_response,
       status: status,
       message: "response body is not a forecast"
     }}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :api_error, status: status, message: error_message(body)}}
  end

  defp handle_response({:error, exception}) do
    {:error,
     %Error{reason: :request_failed, message: Exception.message(exception), cause: exception}}
  end

  # Gateways and proxies can answer 5xx with HTML, so the body may not be the API's JSON.
  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: "no error message in response"
end

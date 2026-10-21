defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location.

  Fields:

    * `:temperature_c` - the temperature in degrees Celsius.
    * `:condition` - the conditions as the string the API sends, such as `"cloudy"`.
    * `:wind_kph` - the wind speed in kilometres per hour.
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
  Returned when the weather API responds with an error, or with a body that is
  not a forecast.

  The `:reason` field says which:

    * `:api_error` - the API responded with a status other than 200. It uses 4xx
      statuses for problems with the request, such as a wrong API key, and 5xx
      statuses for problems on its side. `:api_message` holds the `"error"` text
      from the body, or `nil` when the body had none, for example an HTML error
      page from a proxy.
    * `:invalid_response` - the API responded with status 200, but the body did
      not have the expected fields.

  In both cases `:status` holds the HTTP status and `:body` the decoded response
  body.

  Network failures, such as a timeout or a refused connection, are not wrapped
  in this struct. For those, `WeatherClient.forecast/3` returns the exception
  Req returns, usually `Req.TransportError`.
  """

  @type reason :: :api_error | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer(),
          api_message: String.t() | nil,
          body: term()
        }

  defexception [:reason, :status, :api_message, :body]

  @impl true
  def message(%__MODULE__{reason: :api_error, api_message: nil} = error) do
    "weather API responded with status #{error.status}"
  end

  def message(%__MODULE__{reason: :api_error} = error) do
    "weather API responded with status #{error.status}: #{error.api_message}"
  end

  def message(%__MODULE__{reason: :invalid_response} = error) do
    "weather API responded with a body that is not a forecast: #{inspect(error.body)}"
  end
end

defmodule WeatherClient do
  @moduledoc ~S"""
  Client for the weather HTTP API.

  Create a client with your API key once, then pass it to each request:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))

      case WeatherClient.forecast(client, 52.52, 13.40) do
        {:ok, forecast} -> IO.puts("#{forecast.temperature_c} °C, #{forecast.condition}")
        {:error, exception} -> IO.puts("No forecast: " <> Exception.message(exception))
      end

  The client does not print its API key when inspected, so it can appear in
  logs and crash reports.

  ## Testing

  To keep your tests off the network, send the client's requests to a
  `Req.Test` stub:

      client = WeatherClient.new(api_key: "test", req_options: [plug: {Req.Test, MyApp.Weather}])

      Req.Test.stub(MyApp.Weather, fn conn ->
        Req.Test.json(conn, %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12})
      end)

      {:ok, %WeatherClient.Forecast{condition: "cloudy"}} = WeatherClient.forecast(client, 52.52, 13.40)
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder host: replace with the weather API's real base URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout :timer.seconds(15)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  defstruct [:api_key, :base_url, :timeout, :req_options]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  defguardp is_latitude(value) when is_number(value) and value >= -90 and value <= 90
  defguardp is_longitude(value) when is_number(value) and value >= -180 and value <= 180

  @doc """
  Creates a client.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header of every request.
      Required.
    * `:base_url` - the URL that request paths such as `/forecast` are appended
      to. Defaults to `#{inspect(@default_base_url)}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Passed to
      Req as `:receive_timeout`. Req retries failed requests up to 3 times by
      default, so one call can take longer than this in total. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options for `Req.new/1`, applied after the ones
      above. Use it to stub requests in tests (`plug: {Req.Test, MyApp.Weather}`)
      or to turn off retries (`retry: false`). Defaults to `[]`.

  Raises `ArgumentError` for an unknown option or a missing `:api_key`, and
  `FunctionClauseError` for an option value of the wrong type.

  ## Examples

      iex> client = WeatherClient.new(api_key: "my-api-key", timeout: 5_000)
      iex> client.timeout
      5000

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

    Enum.each(opts, &validate_option/1)
    struct!(__MODULE__, opts)
  end

  @doc """
  Fetches the forecast for a location given in decimal degrees.

  Returns `{:error, %WeatherClient.Error{}}` when the API responds with an
  error or with a body that is not a forecast. Returns `{:error, exception}`
  with Req's exception, such as `Req.TransportError`, when the request does not
  reach the API or times out.

  ## Examples

      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.40)
      forecast.condition
      #=> "cloudy"

  """
  @spec forecast(t(), number(), number()) ::
          {:ok, Forecast.t()} | {:error, Error.t() | Exception.t()}
  def forecast(%__MODULE__{} = client, latitude, longitude)
      when is_latitude(latitude) and is_longitude(longitude) do
    params = [lat: latitude, lon: longitude]

    case Req.get(request(client), url: "/forecast", params: params) do
      {:ok, response} -> handle_response(response)
      {:error, _exception} = error -> error
    end
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly and raises the error
  instead of returning it.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, latitude, longitude) do
    case forecast(client, latitude, longitude) do
      {:ok, forecast} -> forecast
      {:error, exception} -> raise exception
    end
  end

  defp validate_option({:api_key, api_key}) when is_binary(api_key) and api_key != "", do: :ok
  defp validate_option({:base_url, base_url}) when is_binary(base_url), do: :ok
  defp validate_option({:timeout, timeout}) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_option({:req_options, req_options}) when is_list(req_options), do: :ok

  defp request(client) do
    request =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    Req.merge(request, client.req_options)
  end

  defp handle_response(%Req.Response{status: 200} = response), do: parse_forecast(response.body)

  defp handle_response(%Req.Response{} = response) do
    {:error,
     %Error{
       reason: :api_error,
       status: response.status,
       api_message: api_message(response.body),
       body: response.body
     }}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(body) do
    {:error, %Error{reason: :invalid_response, status: 200, body: body}}
  end

  defp api_message(%{"error" => api_message}) when is_binary(api_message), do: api_message
  defp api_message(_body), do: nil
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  The forecast for one location, parsed from the API's JSON response.
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
  The reason a `WeatherClient` call failed.

  `WeatherClient.forecast/3` returns it in `{:error, error}` and `WeatherClient.forecast!/3`
  raises it. The `:reason` field says what went wrong:

    * `:api_error` - the API answered with a status outside 2xx. `:status` holds that
      status and `:detail` the text of the API's `error` field, or `nil` when the body has
      none, as with an HTML error page from a proxy.

    * `:request_failed` - no usable response arrived, because the connection failed, the
      request timed out or the body could not be decoded. `:detail` holds the exception
      from Req, such as `%Req.TransportError{reason: :timeout}`.

    * `:invalid_response` - the API answered 2xx with a body that is not a forecast.
      `:detail` holds that body.
  """

  defexception [:reason, :status, :detail]

  @type t :: %__MODULE__{
          reason: :api_error | :request_failed | :invalid_response,
          status: pos_integer() | nil,
          detail: term()
        }

  @impl Exception
  def message(%__MODULE__{reason: :api_error, detail: nil} = error) do
    "weather API responded with status #{error.status}"
  end

  def message(%__MODULE__{reason: :api_error} = error) do
    "weather API responded with status #{error.status}: #{error.detail}"
  end

  def message(%__MODULE__{reason: :request_failed} = error) do
    "weather API request failed: #{Exception.message(error.detail)}"
  end

  def message(%__MODULE__{reason: :invalid_response} = error) do
    "weather API returned an unexpected body: #{inspect(error.detail)}"
  end
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Build a client with `new/1` and pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 59.33, 18.07)
      forecast.temperature_c
      #=> 21.5

  Failures come back as `{:error, %WeatherClient.Error{}}`. The package reads no
  application configuration, so one system can hold several clients with different
  settings. To vary settings by environment, read them from your own configuration and
  pass them to `new/1`.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder host: replace with the real API's URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout :timer.seconds(5)

  @derive {Inspect, only: [:base_url, :timeout]}
  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client. Raises if an option is unknown, missing or of the wrong type.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header of every request.

    * `:base_url` - the root URL of the API. Defaults to `"#{@default_base_url}"`.

    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`. It applies to each attempt: Req retries timeouts, connection
      errors and the statuses 408, 429, 500, 502, 503 and 504 up to three times, so a
      failing call can take several times longer. Pass `req_options: [retry: false]` to
      make one attempt only.

    * `:req_options` - extra options for `Req.new/1`, applied last so they override the
      settings above. Use it for a stub in tests, as in `req_options: [plug: stub]`.
      Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", timeout: 2_000)
      iex> client.timeout
      2000

      iex> client = WeatherClient.new(api_key: "secret", base_url: "https://weather.test")
      iex> inspect(client)
      ~s(#WeatherClient<base_url: "https://weather.test", timeout: 5000, ...>)
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
      api_key: validate_api_key(Keyword.fetch!(opts, :api_key)),
      base_url: validate_base_url(opts[:base_url]),
      timeout: validate_timeout(opts[:timeout]),
      req_options: validate_req_options(opts[:req_options])
    }
  end

  @doc """
  Returns the forecast for a latitude and longitude in decimal degrees.

  Returns `{:ok, forecast}`, or `{:error, error}` with a `WeatherClient.Error` that says
  what went wrong.

  ## Examples

      iex> stub = fn conn ->
      ...>   body = %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12}
      ...>   Req.Test.json(conn, body)
      ...> end
      iex> client = WeatherClient.new(api_key: "secret", req_options: [plug: stub])
      iex> WeatherClient.forecast(client, 59.33, 18.07)
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

      iex> stub = fn conn ->
      ...>   conn
      ...>   |> Plug.Conn.put_status(404)
      ...>   |> Req.Test.json(%{"error" => "unknown location"})
      ...> end
      iex> client = WeatherClient.new(api_key: "secret", req_options: [plug: stub])
      iex> WeatherClient.forecast(client, 0, 0)
      {:error, %WeatherClient.Error{reason: :api_error, status: 404, detail: "unknown location"}}
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(build_request(client), url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{} = response} ->
        handle_response(response)

      {:error, exception} ->
        {:error, %Error{reason: :request_failed, detail: exception}}
    end
  end

  @doc """
  Returns the forecast like `forecast/3`, but raises `WeatherClient.Error` on failure.

  ## Examples

      iex> stub = &Plug.Conn.send_resp(&1, 401, "")
      iex> client = WeatherClient.new(api_key: "wrong", req_options: [plug: stub])
      iex> WeatherClient.forecast!(client, 59.33, 18.07)
      ** (WeatherClient.Error) weather API responded with status 401
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} ->
        forecast

      {:error, error} ->
        raise error
    end
  end

  defp validate_api_key(api_key) when is_binary(api_key) and api_key != "", do: api_key
  defp validate_base_url(base_url) when is_binary(base_url) and base_url != "", do: base_url
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp validate_req_options(req_options) when is_list(req_options), do: req_options

  defp build_request(%__MODULE__{} = client) do
    options = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout,
      # On a redirect to another host Req drops only the `authorization` header, so
      # following one would send the API key to that host.
      redirect: false
    ]

    Req.merge(Req.new(options), client.req_options)
  end

  defp handle_response(%Req.Response{status: status} = response) when status in 200..299 do
    parse_forecast(response.body)
  end

  defp handle_response(%Req.Response{} = response) do
    error = %Error{
      reason: :api_error,
      status: response.status,
      detail: error_detail(response.body)
    }

    {:error, error}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    forecast = %Forecast{
      temperature_c: temperature_c,
      condition: condition,
      wind_kph: wind_kph
    }

    {:ok, forecast}
  end

  defp parse_forecast(body), do: {:error, %Error{reason: :invalid_response, detail: body}}

  defp error_detail(%{"error" => detail}) when is_binary(detail), do: detail
  defp error_detail(_body), do: nil
end

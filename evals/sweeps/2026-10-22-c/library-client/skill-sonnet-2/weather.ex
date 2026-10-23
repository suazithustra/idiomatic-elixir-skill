defmodule WeatherClient do
  @moduledoc """
  A client for the public weather HTTP API.

  Build a client once with `new/2`, then pass it to `fetch_forecast/3`. Each
  client carries its own API key, base URL and timeout, so one application can
  talk to several accounts or environments at the same time.

  ## Examples

      client = WeatherClient.new("my-api-key", receive_timeout: 10_000)

      {:ok, forecast} = WeatherClient.fetch_forecast(client, 52.52, 13.41)
      forecast.condition
      #=> "cloudy"
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_receive_timeout :timer.seconds(5)

  # The inspected struct omits `:req`, whose headers hold the API key.
  @derive {Inspect, only: [:base_url]}
  @enforce_keys [:base_url, :req]
  defstruct [:base_url, :req]

  @type t :: %__MODULE__{base_url: String.t(), req: Req.Request.t()}

  @doc """
  Builds a client that authenticates with `api_key`.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for the response. Defaults to
      `#{@default_receive_timeout}`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `[plug: {Req.Test, WeatherClient}]` in tests or `[retry: false]`.
      Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", base_url: "http://localhost:4000")
      iex> client.base_url
      "http://localhost:4000"
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        receive_timeout: @default_receive_timeout,
        req_options: []
      )

    build(api_key, opts[:base_url], opts[:receive_timeout], opts[:req_options])
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the request fails, the API answers with an error status, or the response
  body has an unexpected shape.

  ## Examples

      client = WeatherClient.new("my-api-key")

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5}} =
        WeatherClient.fetch_forecast(client, 52.52, 13.41)

      {:error, %WeatherClient.Error{reason: :api_error, status: 401}} =
        WeatherClient.fetch_forecast(WeatherClient.new("bad-key"), 52.52, 13.41)
  """
  @spec fetch_forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def fetch_forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, response} -> parse_response(response)
      {:error, exception} -> {:error, Error.transport(exception)}
    end
  end

  @doc """
  Same as `fetch_forecast/3`, but returns the forecast directly and raises a
  `WeatherClient.Error` on failure.
  """
  @spec fetch_forecast!(t(), number(), number()) :: Forecast.t()
  def fetch_forecast!(client, lat, lon) do
    case fetch_forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build(api_key, base_url, receive_timeout, req_options)
       when is_binary(base_url) and is_integer(receive_timeout) and receive_timeout > 0 and
              is_list(req_options) do
    req =
      Req.new(
        base_url: base_url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: receive_timeout
      )

    %__MODULE__{base_url: base_url, req: Req.merge(req, req_options)}
  end

  defp parse_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    Forecast.parse(body)
  end

  defp parse_response(%Req.Response{status: status, body: body}) do
    {:error, Error.api_error(status, body)}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast as returned by the weather API.

  `condition` is kept as the API's own string, because the set of conditions
  is owned by the API and may grow.
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
    forecast = %__MODULE__{
      temperature_c: temperature_c,
      condition: condition,
      wind_kph: wind_kph
    }

    {:ok, forecast}
  end

  def parse(body), do: {:error, Error.invalid_response(body)}
end

defmodule WeatherClient.Error do
  @moduledoc """
  The reason of every `{:error, reason}` returned by `WeatherClient`.

  The `:reason` field says what kind of failure happened:

    * `:api_error` - the API answered with a 4xx/5xx status. `:status` holds the
      status and `:message` the API's `"error"` text when it sent one.
    * `:transport` - the request never got a response, for example a timeout or a
      refused connection. `:details` holds the underlying exception.
    * `:invalid_response` - the API answered successfully with a body that is not a
      forecast. `:details` holds the body.
  """

  @enforce_keys [:reason]
  defexception [:reason, :status, :message, :details]

  @type t :: %__MODULE__{
          reason: :api_error | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t() | nil,
          details: term()
        }

  @doc false
  @spec api_error(pos_integer(), term()) :: t()
  def api_error(status, %{"error" => message}) when is_binary(message) do
    %__MODULE__{reason: :api_error, status: status, message: "API error #{status}: #{message}"}
  end

  def api_error(status, _body) do
    %__MODULE__{reason: :api_error, status: status, message: "API error #{status}"}
  end

  @doc false
  @spec transport(Exception.t()) :: t()
  def transport(exception) do
    message = "request failed: " <> Exception.message(exception)
    %__MODULE__{reason: :transport, message: message, details: exception}
  end

  @doc false
  @spec invalid_response(term()) :: t()
  def invalid_response(body) do
    %__MODULE__{
      reason: :invalid_response,
      message: "unexpected response body: #{inspect(body)}",
      details: body
    }
  end
end

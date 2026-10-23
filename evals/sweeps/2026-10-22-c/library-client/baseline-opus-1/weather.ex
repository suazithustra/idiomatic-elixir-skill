defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client with `new/1` and pass it to the request functions:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.40)
      forecast.temperature_c
      #=> 21.5

  The library reads no application environment; all configuration is passed
  explicitly to `new/1`.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 15_000

  @enforce_keys [:req]
  defstruct [:req]

  @typedoc "A configured client. Treat as opaque."
  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a new client.

  ## Options

    * `:api_key` (required) - the API key sent in the `x-api-key` header.
    * `:base_url` - the API base URL. Defaults to `#{inspect(@default_base_url)}`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `[plug: {Req.Test, WeatherClient}]` in tests or `[retry: false]`.
      Defaults to `[]`.
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

    api_key = Keyword.fetch!(opts, :api_key)

    unless is_binary(api_key) and api_key != "" do
      raise ArgumentError, ":api_key must be a non-empty string, got: #{inspect(api_key)}"
    end

    timeout = opts[:timeout]

    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError, ":timeout must be a positive integer, got: #{inspect(timeout)}"
    end

    req =
      Req.new(
        base_url: opts[:base_url],
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout
      )
      |> Req.merge(opts[:req_options])

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the forecast for the given coordinates.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success or
  `{:error, %WeatherClient.Error{}}` on failure.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Forecast.from_map(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.http(status, body)}

      {:error, exception} ->
        {:error, Error.transport(exception)}
    end
  end

  @doc """
  Same as `forecast/3` but returns the forecast directly or raises
  `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast.

  `condition` is kept as the string returned by the API (for example
  `"cloudy"`), so new conditions added by the API don't break the client.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(term()) :: {:ok, t()} | {:error, WeatherClient.Error.t()}
  def from_map(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
      when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def from_map(body) do
    {:error, WeatherClient.Error.invalid_response(body)}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient`.

  The `:reason` field is one of:

    * `:http_error` - the API responded with a non-2xx status. `:status` is set
      and `:message` holds the API's `"error"` message when available.
    * `:transport_error` - the request could not be completed (connection
      refused, timeout, ...). `:exception` holds the underlying exception.
    * `:invalid_response` - the API responded with 2xx but an unexpected body.
      `:body` holds the body as received.
  """

  defexception [:reason, :message, :status, :body, :exception]

  @type reason :: :http_error | :transport_error | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          status: non_neg_integer() | nil,
          body: term(),
          exception: Exception.t() | nil
        }

  @doc false
  def http(status, %{"error" => message} = body) when is_binary(message) do
    %__MODULE__{reason: :http_error, status: status, body: body, message: message}
  end

  def http(status, body) do
    %__MODULE__{reason: :http_error, status: status, body: body, message: "HTTP #{status}"}
  end

  @doc false
  def transport(exception) do
    %__MODULE__{
      reason: :transport_error,
      exception: exception,
      message: Exception.message(exception)
    }
  end

  @doc false
  def invalid_response(body) do
    %__MODULE__{
      reason: :invalid_response,
      body: body,
      message: "unexpected response body: #{inspect(body)}"
    }
  end

  @impl true
  def message(%__MODULE__{reason: :http_error, status: status, message: message}) do
    "weather API returned #{status}: #{message}"
  end

  def message(%__MODULE__{message: message}), do: message
end

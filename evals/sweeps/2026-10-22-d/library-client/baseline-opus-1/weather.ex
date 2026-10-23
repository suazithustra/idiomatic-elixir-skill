defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client with `new/1` and pass it to the request functions:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5}} =
        WeatherClient.forecast(client, 52.52, 13.405)

  The client is a plain struct, so you can build as many as you need (for
  example, one per API key) and keep them wherever suits your application.
  This library reads no application environment.

  ## Testing

  Any extra Req options can be passed through `:req_options`, which makes it
  easy to stub requests with `Req.Test`:

      client = WeatherClient.new(api_key: "test", req_options: [plug: {Req.Test, WeatherClient}])
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 15_000

  @enforce_keys [:req]
  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}

  @typedoc "Latitude or longitude in decimal degrees."
  @type coordinate :: number()

  defimpl Inspect do
    # The underlying request holds the API key, so keep it out of logs.
    def inspect(%{req: req}, _opts) do
      "#WeatherClient<base_url: #{inspect(req.options[:base_url])}>"
    end
  end

  @doc """
  Builds a new client.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header. Required.

    * `:base_url` - the API base URL. Defaults to `#{inspect(@default_base_url)}`.

    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.

    * `:req_options` - additional options passed to `Req.new/1`. These take
      precedence over the options above.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      ])

    api_key =
      case Keyword.fetch(opts, :api_key) do
        {:ok, key} when is_binary(key) and key != "" ->
          key

        _ ->
          raise ArgumentError, ":api_key is required and must be a non-empty string"
      end

    req =
      [
        base_url: opts[:base_url],
        headers: [{"x-api-key", api_key}],
        receive_timeout: opts[:timeout]
      ]
      |> Req.new()
      |> Req.merge(opts[:req_options])

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for the given coordinates.

  Returns `{:ok, forecast}` on success, or `{:error, exception}` where the
  exception is a `WeatherClient.Error`.
  """
  @spec forecast(t(), coordinate(), coordinate()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Forecast.from_map(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.api_error(status, body)}

      {:error, exception} ->
        {:error, Error.transport_error(exception)}
    end
  end

  @doc """
  Same as `forecast/3` but returns the forecast directly or raises
  `WeatherClient.Error`.
  """
  @spec forecast!(t(), coordinate(), coordinate()) :: Forecast.t()
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

  `:condition` is kept as the string returned by the API (for example,
  `"cloudy"`), since the set of possible values is defined by the API.
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

  The `:reason` field identifies the kind of failure:

    * `:api_error` - the API responded with a non-2xx status. `:status` holds
      the HTTP status and `:message` the API's error message, when present.

    * `:transport_error` - the request did not complete (for example, a
      timeout or connection failure). `:cause` holds the underlying exception.

    * `:invalid_response` - the API responded successfully but the body
      wasn't in the expected format. `:body` holds the received body.
  """

  defexception [:reason, :status, :message, :body, :cause]

  @type reason :: :api_error | :transport_error | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          message: String.t(),
          body: term(),
          cause: Exception.t() | nil
        }

  @doc false
  def api_error(status, %{"error" => message} = body) when is_binary(message) do
    %__MODULE__{reason: :api_error, status: status, message: message, body: body}
  end

  def api_error(status, body) do
    %__MODULE__{reason: :api_error, status: status, message: "HTTP #{status}", body: body}
  end

  @doc false
  def transport_error(exception) do
    %__MODULE__{
      reason: :transport_error,
      message: Exception.message(exception),
      cause: exception
    }
  end

  @doc false
  def invalid_response(body) do
    %__MODULE__{reason: :invalid_response, message: "unexpected response body", body: body}
  end

  @impl true
  def message(%__MODULE__{reason: :api_error, status: status, message: message}) do
    "weather API error (HTTP #{status}): #{message}"
  end

  def message(%__MODULE__{reason: :transport_error, message: message}) do
    "weather API request failed: #{message}"
  end

  def message(%__MODULE__{reason: :invalid_response, body: body}) do
    "weather API returned an unexpected response: #{inspect(body)}"
  end
end

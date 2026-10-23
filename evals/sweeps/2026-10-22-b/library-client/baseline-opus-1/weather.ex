defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client with `new/1` and pass it to the request functions:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5}} = WeatherClient.forecast(client, 52.52, 13.40)

  The client is a plain struct, so it can be created once and shared
  between processes. No application environment is read; all configuration
  is passed explicitly to `new/1`.
  """

  alias WeatherClient.{Error, Forecast}

  @enforce_keys [:req]
  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 5_000

  @doc """
  Builds a new client.

  ## Options

    * `:api_key` (required) - the API key sent in the `x-api-key` header.
    * `:base_url` - the API base URL. Defaults to `#{inspect(@default_base_url)}`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `[retry: false]` or `[plug: {Req.Test, WeatherClient}]` in tests.
      These are merged last and take precedence.
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

    api_key = opts[:api_key]

    unless is_binary(api_key) and api_key != "" do
      raise ArgumentError, ":api_key is required and must be a non-empty string"
    end

    req =
      Req.new(
        base_url: opts[:base_url],
        headers: [{"x-api-key", api_key}],
        receive_timeout: opts[:timeout]
      )
      |> Req.merge(opts[:req_options])

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the forecast for the given coordinates.

  Returns `{:ok, forecast}` on success or `{:error, exception}` where the
  exception is a `WeatherClient.Error` (API error or unexpected response) or
  a Req/Mint transport exception (e.g. `Req.TransportError` on timeout).
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Exception.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Forecast.from_map(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.from_response(status, body)}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc """
  Same as `forecast/3` but returns the forecast directly or raises on error.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, exception} -> raise exception
    end
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast.

  `condition` is kept as the string returned by the API (e.g. `"cloudy"`)
  rather than converted to an atom, so unknown values never create atoms.
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
  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
      when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def from_map(body) do
    {:error,
     %Error{reason: :invalid_response, status: 200, message: "unexpected response body", body: body}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by the weather API or an unexpected response.

  Fields:

    * `:reason` - `:api_error` when the API returned a 4xx/5xx status,
      `:invalid_response` when the response could not be understood.
    * `:status` - the HTTP status code.
    * `:message` - the `"error"` message from the API, if any.
    * `:body` - the raw response body.
  """

  defexception [:reason, :status, :message, :body]

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response,
          status: non_neg_integer() | nil,
          message: String.t() | nil,
          body: term()
        }

  @impl true
  def message(%__MODULE__{status: status, message: message}) do
    "weather API error (HTTP #{status}): #{message || "no error message"}"
  end

  @doc false
  @spec from_response(non_neg_integer(), term()) :: t()
  def from_response(status, %{"error" => message} = body) when is_binary(message) do
    %__MODULE__{reason: :api_error, status: status, message: message, body: body}
  end

  def from_response(status, body) when status >= 400 do
    %__MODULE__{reason: :api_error, status: status, message: nil, body: body}
  end

  def from_response(status, body) do
    %__MODULE__{reason: :invalid_response, status: status, message: "unexpected status", body: body}
  end
end

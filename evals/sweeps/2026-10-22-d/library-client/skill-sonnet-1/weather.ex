defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client once with `new/1` and pass it to `forecast/3`. Each client
  carries its own API key, base URL and timeout, so several differently
  configured clients can live side by side.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:req]}
  @enforce_keys [:req]
  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header. Required.
    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      such as `plug:` for stubbing in tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", timeout: 2_000)
      iex> match?(%WeatherClient{}, client)
      true
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    defaults = [
      :api_key,
      base_url: @default_base_url,
      timeout: @default_timeout,
      req_options: []
    ]

    opts = Keyword.validate!(opts, defaults)
    api_key = Keyword.fetch!(opts, :api_key)

    build(api_key, opts[:base_url], opts[:timeout], opts[:req_options])
  end

  defp build(api_key, base_url, timeout, req_options)
       when is_binary(api_key) and is_binary(base_url) and is_integer(timeout) and timeout > 0 and
              is_list(req_options) do
    req =
      [base_url: base_url, headers: [{"x-api-key", api_key}], receive_timeout: timeout]
      |> Keyword.merge(req_options)
      |> Req.new()

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for a coordinate.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the request fails, the API answers with an error status, or the response
  body is not a forecast.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lon) and lon >= -180 and
             lon <= 180 do
    case Req.get(client.req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: body}} -> Forecast.parse(body)
      {:ok, %Req.Response{} = response} -> {:error, Error.from_response(response)}
      {:error, exception} -> {:error, Error.from_exception(exception)}
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
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by the weather API.
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
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def parse(body), do: {:error, %Error{reason: :invalid_response, details: body}}
end

defmodule WeatherClient.Error do
  @moduledoc """
  The reason of a failed `WeatherClient` call.

  The `:reason` field is one of:

    * `:api_error` - the API answered with an error status. `:status` holds the
      HTTP status and `:details` the message from the API, when it sent one.
    * `:invalid_response` - the API answered successfully, but the body is not a
      forecast. `:details` holds the body.
    * `:request_failed` - no response arrived, for example on a timeout or a
      refused connection. `:details` holds the underlying exception.
  """

  defexception [:reason, :status, :details]

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :request_failed,
          status: pos_integer() | nil,
          details: term()
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, status: status, details: message})
      when is_binary(message) do
    "weather API returned status #{status}: #{message}"
  end

  def message(%__MODULE__{reason: :api_error, status: status}) do
    "weather API returned status #{status}"
  end

  def message(%__MODULE__{reason: :invalid_response, details: body}) do
    "weather API returned an unexpected body: #{inspect(body)}"
  end

  def message(%__MODULE__{reason: :request_failed, details: exception}) do
    "request to the weather API failed: #{Exception.message(exception)}"
  end

  @doc false
  @spec from_response(Req.Response.t()) :: t()
  def from_response(%Req.Response{status: status, body: %{"error" => message}}) do
    %__MODULE__{reason: :api_error, status: status, details: message}
  end

  def from_response(%Req.Response{status: status}) do
    %__MODULE__{reason: :api_error, status: status}
  end

  @doc false
  @spec from_exception(Exception.t()) :: t()
  def from_exception(exception) when is_exception(exception) do
    %__MODULE__{reason: :request_failed, details: exception}
  end
end

defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  ## Options

  `new/1` accepts:

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example")}`.
    * `:timeout` - response receive timeout in milliseconds. Defaults to `10_000`.
    * `:req_options` - extra options merged into the underlying `Req` request
      (for example `plug: {Req.Test, WeatherClient}` in tests, or `retry: false`).

  Defaults for `:base_url` and `:timeout` can also be set in application config:

      config :weather_client, base_url: "https://weather.internal", timeout: 5_000
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 10_000

  @type t :: %__MODULE__{req: Req.Request.t()}

  @enforce_keys [:req]
  defstruct [:req]

  @doc """
  Builds a client. Raises `KeyError` if `:api_key` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    base_url = Keyword.get(opts, :base_url, config(:base_url, @default_base_url))
    timeout = Keyword.get(opts, :timeout, config(:timeout, @default_timeout))
    req_options = Keyword.get(opts, :req_options, [])

    req =
      Req.new(
        base_url: base_url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout
      )
      |> Req.merge(req_options)

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Forecast.from_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.from_response(status, body)}

      {:error, exception} ->
        {:error, %Error{reason: :transport, message: Exception.message(exception)}}
    end
  end

  @doc """
  Same as `forecast/3` but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp config(key, default), do: Application.get_env(:weather_client, key, default)
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by the weather API.
  """

  alias WeatherClient.Error

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @doc false
  @spec from_body(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_body(%{
        "temperature_c" => temperature_c,
        "condition" => condition,
        "wind_kph" => wind_kph
      }) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def from_body(_body) do
    {:error, %Error{reason: :invalid_response, message: "unexpected forecast response body"}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned (or raised, by bang functions) by `WeatherClient`.

  `:reason` is one of:

    * `:unauthorized` - 401 or 403, usually a bad API key
    * `:rate_limited` - 429
    * `:client_error` - other 4xx
    * `:server_error` - 5xx
    * `:transport` - the request never got a response (timeout, connection refused, ...)
    * `:invalid_response` - a success response with an unexpected body

  `:status` is the HTTP status when there was a response, otherwise `nil`.
  """

  @type reason ::
          :unauthorized
          | :rate_limited
          | :client_error
          | :server_error
          | :transport
          | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          message: String.t() | nil
        }

  defexception [:reason, :status, :message]

  @doc false
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, body) do
    %__MODULE__{reason: reason_for(status), status: status, message: message_from(body, status)}
  end

  defp reason_for(status) when status in [401, 403], do: :unauthorized
  defp reason_for(429), do: :rate_limited
  defp reason_for(status) when status in 400..499, do: :client_error
  defp reason_for(_status), do: :server_error

  defp message_from(%{"error" => message}, _status) when is_binary(message), do: message
  defp message_from(_body, status), do: "HTTP #{status}"
end

defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.temperature_c
      #=> 21.5

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:timeout` - response timeout in milliseconds. Defaults to `10_000`.
    * `:req_options` - extra options merged into the underlying `Req` request
      (for example `retry: false` or `plug: {Req.Test, WeatherClient}` in tests).

  The defaults can also be set application-wide:

      config :weather_client, base_url: "https://...", timeout: 5_000
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 10_000

  @enforce_keys [:req]
  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client. Raises `KeyError` if `:api_key` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    base_url = Keyword.get_lazy(opts, :base_url, fn -> config(:base_url, @default_base_url) end)
    timeout = Keyword.get_lazy(opts, :timeout, fn -> config(:timeout, @default_timeout) end)
    req_options = Keyword.get(opts, :req_options, [])

    req =
      [
        base_url: base_url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout
      ]
      |> Req.new()
      |> Req.merge(req_options)

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for a latitude/longitude.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Forecast.from_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{type: :api, status: status, message: error_message(body)}}

      {:error, exception} ->
        {:error, %Error{type: :transport, message: Exception.message(exception), reason: exception}}
    end
  end

  @doc """
  Like `forecast/3` but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: "unexpected error response"

  defp config(key, default), do: Application.get_env(:weather_client, key, default)
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by the API.
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
  @spec from_body(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_body(%{
        "temperature_c" => temperature_c,
        "condition" => condition,
        "wind_kph" => wind_kph
      }) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def from_body(_body) do
    {:error, %Error{type: :invalid_response, message: "response is missing forecast fields"}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient`.

  `:type` is one of:

    * `:api` - the server replied with a non-2xx status; `:status` is set.
    * `:transport` - the request failed (timeout, connection refused, ...);
      `:reason` holds the underlying exception.
    * `:invalid_response` - a 2xx reply that did not look like a forecast.
  """

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          message: String.t(),
          status: pos_integer() | nil,
          reason: Exception.t() | nil
        }

  defexception [:type, :message, :status, :reason]
end

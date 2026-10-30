defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.temperature_c
      #=> 21.5

  ## Options

  Accepted by `new/1`:

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:timeout` - response timeout in milliseconds. Defaults to `5_000`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `plug: {Req.Test, WeatherClient}` in tests or `retry: false`.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 5_000

  @type t :: Req.Request.t()

  @doc """
  Builds a client. Raises `KeyError` if `:api_key` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    req_options = Keyword.get(opts, :req_options, [])

    [
      base_url: base_url,
      receive_timeout: timeout,
      headers: [{"x-api-key", api_key}]
    ]
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%Req.Request{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(client, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
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
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast returned by the weather API."

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

  def from_body(body) do
    {:error,
     %Error{
       reason: :unexpected_body,
       message: "unexpected response body: #{inspect(body)}"
     }}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient`.

  `:reason` is one of:

    * `:api` - the API answered with a 4xx/5xx; `:status` is set.
    * `:transport` - the request failed before a response arrived (timeout, DNS, connection).
    * `:unexpected_body` - a 200 response did not have the expected shape.
  """

  defexception [:reason, :status, :message]

  @type t :: %__MODULE__{
          reason: :api | :transport | :unexpected_body,
          status: pos_integer() | nil,
          message: String.t()
        }

  @doc false
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, %{"error" => message}) when is_binary(message) do
    %__MODULE__{reason: :api, status: status, message: message}
  end

  def from_response(status, body) do
    %__MODULE__{reason: :api, status: status, message: "HTTP #{status}: #{inspect(body)}"}
  end
end

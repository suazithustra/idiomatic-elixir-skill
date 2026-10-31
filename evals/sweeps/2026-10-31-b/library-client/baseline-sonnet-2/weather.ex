defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  ## Options for `new/1`

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - API root. Defaults to `#{inspect("https://api.weather.example")}`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `5_000`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `[plug: {Req.Test, WeatherClient}]` in tests or `[retry: false]`.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  @enforce_keys [:req]
  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client. Raises `KeyError` if `:api_key` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    req_options = Keyword.get(opts, :req_options, [])

    req =
      [
        base_url: base_url,
        receive_timeout: timeout,
        headers: [{"x-api-key", api_key}]
      ]
      |> Keyword.merge(req_options)
      |> Req.new()

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Forecast.from_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.from_response(status, body)}

      {:error, exception} ->
        {:error, %Error{reason: :transport, message: Exception.message(exception), details: exception}}
    end
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc "A parsed forecast response."

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
  def from_body(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
      when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def from_body(body) do
    {:error, %Error{reason: :invalid_response, message: "unexpected response body", details: body}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient`.

  `:reason` is one of:

    * `:api_error` - the API answered with a non-2xx status; `:status` is set.
    * `:transport` - the request failed before a response arrived (timeout,
      connection refused, ...); `:details` holds the underlying exception.
    * `:invalid_response` - a 2xx response whose body was not the expected shape.
  """

  defexception [:reason, :status, :message, :details]

  @type t :: %__MODULE__{
          reason: :api_error | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t(),
          details: term()
        }

  @doc false
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, %{"error" => message}) when is_binary(message) do
    %__MODULE__{reason: :api_error, status: status, message: message, details: nil}
  end

  def from_response(status, body) do
    %__MODULE__{
      reason: :api_error,
      status: status,
      message: "HTTP #{status}",
      details: body
    }
  end
end

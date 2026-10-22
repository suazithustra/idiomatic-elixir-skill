defmodule WeatherClient do
  @moduledoc """
  A small client for the public weather HTTP API.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
      #=> 21.5

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:timeout` - receive timeout in milliseconds, defaults to `10_000`.
    * `:req_options` - extra options merged into the underlying `Req` request
      (for example `plug: {Req.Test, MyStub}` in tests, or `retry: false`).
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 10_000

  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client. Raises `ArgumentError` if `:api_key` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    api_key =
      case Keyword.fetch(opts, :api_key) do
        {:ok, key} when is_binary(key) and key != "" -> key
        _ -> raise ArgumentError, "WeatherClient requires a non-empty :api_key option"
      end

    base_options = [
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
      headers: [{"x-api-key", api_key}]
    ]

    req =
      base_options
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for the given coordinates.
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
  Like `forecast/3` but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, %Error{} = error} -> raise error
    end
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: "unexpected error response"
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast.
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
  def from_body(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
      when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def from_body(_body) do
    {:error, %Error{type: :invalid_response, message: "malformed forecast payload"}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned (or raised) by `WeatherClient`.

  `:type` is one of:

    * `:api` - the server answered with a non-2xx status; see `:status`
    * `:transport` - the request failed (timeout, connection refused, ...);
      the underlying exception is in `:reason`
    * `:invalid_response` - a 2xx response with an unexpected body
  """

  defexception [:type, :message, :status, :reason]

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          message: String.t(),
          status: non_neg_integer() | nil,
          reason: Exception.t() | nil
        }
end

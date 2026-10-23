defmodule WeatherClient do
  @moduledoc """
  A small client for the public weather HTTP API.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
      #=> 21.5

  ## Options

  `new/1` accepts:

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:timeout` - receive timeout in milliseconds, defaults to `15_000`.
    * `:req_options` - extra options merged into the underlying `Req` request
      (for example `plug: {Req.Test, WeatherClient}` in tests).
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 15_000

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
      Req.new(
        base_url: base_url,
        receive_timeout: timeout,
        headers: [{"x-api-key", api_key}]
      )
      |> Req.merge(req_options)

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for the given coordinates.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_forecast(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{type: :api, status: status, message: error_message(body)}}

      {:error, exception} ->
        {:error, %Error{type: :transport, message: Exception.message(exception), reason: exception}}
    end
  end

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind}) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(body) do
    {:error, %Error{type: :invalid_response, message: "unexpected response body: #{inspect(body)}"}}
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body) and body != "", do: body
  defp error_message(_body), do: "unknown error"
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast returned by the weather API."

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` functions.

  `:type` is one of:

    * `:api` - the server replied with a non-2xx status; `:status` is set.
    * `:transport` - the request failed (timeout, connection refused, ...);
      `:reason` holds the underlying exception.
    * `:invalid_response` - a 2xx reply whose body wasn't a valid forecast.
  """

  defexception [:type, :status, :message, :reason]

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          status: non_neg_integer() | nil,
          message: String.t(),
          reason: Exception.t() | nil
        }
end

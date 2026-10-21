defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.get_forecast(client, 52.52, 13.405)
      forecast.temperature_c
      #=> 21.5

  ## Options

  Options are given to `new/1`:

    * `:api_key` (required) - sent in the `x-api-key` header on every request.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `5_000`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `[plug: {Req.Test, WeatherClient}]` in tests or `[retry: false]`.

  The client holds no global state, so several clients with different keys or
  base URLs can be used side by side.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 5_000

  @enforce_keys [:req]
  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client. Raises `ArgumentError` if `:api_key` is missing or empty.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    api_key = Keyword.get(opts, :api_key)

    unless is_binary(api_key) and api_key != "" do
      raise ArgumentError, "WeatherClient requires a non-empty :api_key option"
    end

    base_url = Keyword.get(opts, :base_url, @default_base_url)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
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
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec get_forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def get_forecast(%__MODULE__{req: req}, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_forecast(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{type: :http, status: status, message: error_message(body)}}

      {:error, exception} ->
        {:error, %Error{type: :transport, message: Exception.message(exception), reason: exception}}
    end
  end

  def get_forecast(%__MODULE__{}, lat, lon) do
    {:error,
     %Error{
       type: :invalid_params,
       message: "lat must be within -90..90 and lon within -180..180, got: #{inspect({lat, lon})}"
     }}
  end

  @doc """
  Same as `get_forecast/3` but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec get_forecast!(t(), number(), number()) :: Forecast.t()
  def get_forecast!(client, lat, lon) do
    case get_forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(body) do
    {:error,
     %Error{
       type: :unexpected_response,
       message: "unexpected forecast body: #{inspect(body)}"
     }}
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body) and body != "", do: body
  defp error_message(_body), do: nil
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
  Error returned (or raised by bang functions) by `WeatherClient`.

  `:type` is one of:

    * `:http` - the API replied with a non-2xx status; see `:status`.
    * `:transport` - the request failed before a response arrived (timeout,
      connection refused, ...); the original exception is in `:reason`.
    * `:unexpected_response` - a 2xx reply whose body was not a forecast.
    * `:invalid_params` - rejected locally before any request was made.
  """

  @type t :: %__MODULE__{
          type: :http | :transport | :unexpected_response | :invalid_params,
          status: non_neg_integer() | nil,
          message: String.t() | nil,
          reason: Exception.t() | nil
        }

  defexception [:type, :status, :message, :reason]

  @impl true
  def message(%__MODULE__{type: :http, status: status, message: message}) do
    "weather API returned HTTP #{status}" <> if(message, do: ": #{message}", else: "")
  end

  def message(%__MODULE__{type: type, message: message}) do
    "weather API #{type}: #{message}"
  end
end

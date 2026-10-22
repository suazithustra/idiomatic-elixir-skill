defmodule WeatherClient do
  @moduledoc """
  A small client for the public weather HTTP API, built on `Req`.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.temperature_c
      #=> 21.5

  ## Options

  `new/1` accepts:

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:timeout` - receive timeout in milliseconds, defaults to `10_000`.
    * `:req_options` - extra options merged into the underlying `Req` request
      (for example `retry: false` or `plug: {Req.Test, WeatherClient}` in tests).
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 10_000

  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}

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

    base_url = Keyword.get(opts, :base_url, @default_base_url)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
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
  Fetches the current forecast for the given coordinates.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_forecast(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{type: :api, status: status, message: error_message(body, status)}}

      {:error, exception} ->
        {:error, %Error{type: :transport, status: nil, message: Exception.message(exception), reason: exception}}
    end
  end

  @doc """
  Like `forecast/3` but returns the forecast directly and raises `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
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
       type: :invalid_response,
       status: nil,
       message: "unexpected forecast response: #{inspect(body)}"
     }}
  end

  defp error_message(%{"error" => message}, _status) when is_binary(message), do: message
  defp error_message(_body, status), do: "request failed with status #{status}"
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
  Error returned (or raised by bang functions) when a request fails.

  `:type` is one of:

    * `:api` - the API replied with a non-2xx status; `:status` is set.
    * `:transport` - the request never completed (timeout, connection refused, ...);
      `:reason` holds the underlying exception.
    * `:invalid_response` - a 2xx reply whose body did not look like a forecast.
  """

  defexception [:type, :status, :message, :reason]

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          status: non_neg_integer() | nil,
          message: String.t(),
          reason: Exception.t() | nil
        }
end

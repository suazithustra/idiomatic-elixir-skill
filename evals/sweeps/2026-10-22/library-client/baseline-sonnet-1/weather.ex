defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
      #=> 21.5

  ## Options

  Accepted by `new/1`:

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:receive_timeout` - milliseconds to wait for a response. Defaults to `5_000`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `plug: {Req.Test, WeatherClient}` in tests.

  Defaults for `:api_key`, `:base_url` and `:receive_timeout` can also be set
  in the application environment:

      config :weather_client, api_key: "secret", receive_timeout: 10_000

  Options passed to `new/1` take precedence.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_receive_timeout 5_000

  @enforce_keys [:req]
  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client. Raises `ArgumentError` if no API key is available.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.merge(Application.get_all_env(:weather_client), opts)

    api_key =
      case Keyword.fetch(opts, :api_key) do
        {:ok, key} when is_binary(key) and key != "" -> key
        _ -> raise ArgumentError, "WeatherClient requires a non-empty :api_key"
      end

    req =
      Req.new(
        base_url: Keyword.get(opts, :base_url, @default_base_url),
        receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
        headers: [{"x-api-key", api_key}]
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` for API errors (4xx/5xx), transport
  failures such as timeouts, and unexpected response bodies.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        parse_forecast(body)

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error, %Error{reason: :invalid_response, status: status, message: inspect(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{reason: :api_error, status: status, message: error_message(body)}}

      {:error, exception} ->
        {:error, %Error{reason: :transport, message: Exception.message(exception)}}
    end
  end

  @doc """
  Same as `forecast/3` but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
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
    {:error, %Error{reason: :invalid_response, status: 200, message: inspect(body)}}
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body) and body != "", do: body
  defp error_message(_body), do: nil
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast returned by `WeatherClient.forecast/3`."

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

  `:reason` is one of:

    * `:api_error` - the API answered with a 4xx/5xx; `:status` and `:message` are set.
    * `:transport` - the request never got a response (timeout, connection refused, ...).
    * `:invalid_response` - the API answered 2xx with a body in an unexpected shape.
  """

  defexception [:reason, :status, :message]

  @type t :: %__MODULE__{
          reason: :api_error | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, status: status, message: message}) do
    "weather API returned #{status}" <> if(message, do: ": #{message}", else: "")
  end

  def message(%__MODULE__{reason: reason, message: message}) do
    "weather request failed (#{reason})" <> if(message, do: ": #{message}", else: "")
  end
end

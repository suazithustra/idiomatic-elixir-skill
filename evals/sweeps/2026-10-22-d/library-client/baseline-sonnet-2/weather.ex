defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when the weather API responds with a non-success status
  or the request fails at the transport level.

  * `:status` - the HTTP status code, or `nil` for transport errors
  * `:message` - the API's `"error"` message, or a description of the failure
  * `:reason` - the underlying transport exception, if any
  """

  defexception [:status, :message, :reason]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          message: String.t(),
          reason: Exception.t() | nil
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast for a single location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(map()) :: t()
  def from_map(%{} = body) do
    %__MODULE__{
      temperature_c: body["temperature_c"],
      condition: body["condition"],
      wind_kph: body["wind_kph"]
    }
  end
end

defmodule WeatherClient do
  @moduledoc """
  A small client for the weather HTTP API.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)

  ## Options

  `new/1` accepts:

    * `:api_key` - the API key, sent in the `x-api-key` header. Required.
      Falls back to `config :weather_client, :api_key`.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example")}`.
      Falls back to `config :weather_client, :base_url`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `10_000`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      e.g. `[plug: {Req.Test, WeatherClient}]` in tests or `[retry: false]`.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 10_000

  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a new client.

  Raises `ArgumentError` if no API key is available.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    api_key =
      Keyword.get(opts, :api_key) || Application.get_env(:weather_client, :api_key) ||
        raise ArgumentError,
              "missing :api_key; pass it to WeatherClient.new/1 or set " <>
                "config :weather_client, :api_key"

    base_url =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:weather_client, :base_url, @default_base_url)

    timeout = Keyword.get(opts, :timeout, @default_timeout)
    req_options = Keyword.get(opts, :req_options, [])

    req =
      [
        base_url: base_url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout
      ]
      |> Keyword.merge(req_options)
      |> Req.new()

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for the given coordinates.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: %{} = body}} when status in 200..299 ->
        {:ok, Forecast.from_map(body)}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error, %Error{status: status, message: "unexpected response body: #{inspect(body)}"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{status: status, message: error_message(status, body)}}

      {:error, exception} ->
        {:error, %Error{message: Exception.message(exception), reason: exception}}
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

  defp error_message(_status, %{"error" => message}) when is_binary(message), do: message
  defp error_message(status, _body), do: "request failed with status #{status}"
end

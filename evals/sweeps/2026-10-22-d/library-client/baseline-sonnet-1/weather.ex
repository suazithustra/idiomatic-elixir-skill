defmodule WeatherClient do
  @moduledoc """
  A small client for the public weather HTTP API, built on `Req`.

  ## Usage

      client = WeatherClient.new(api_key: "secret")

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5}} =
        WeatherClient.forecast(client, 52.52, 13.405)

  ## Options

  Options given to `new/1`:

    * `:api_key` - the API key sent in the `x-api-key` header. Required, unless
      configured with `config :weather_client, api_key: "..."`.
    * `:base_url` - the API base URL. Defaults to `#{inspect("https://api.weather.example.com")}`
      (or `config :weather_client, base_url: "..."`).
    * `:timeout` - the response receive timeout in milliseconds. Defaults to
      `#{5_000}`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      e.g. `plug: {Req.Test, WeatherClient}` in tests or `retry: false`.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 5_000

  @type t :: Req.Request.t()

  @doc """
  Builds a client (a `Req.Request`) that can be passed to `forecast/4`.

  Raises `ArgumentError` if no API key is available.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    api_key =
      Keyword.get_lazy(opts, :api_key, fn -> Application.get_env(:weather_client, :api_key) end) ||
        raise ArgumentError,
              "missing :api_key; pass it to WeatherClient.new/1 or set " <>
                "config :weather_client, api_key: \"...\""

    base_url =
      Keyword.get_lazy(opts, :base_url, fn ->
        Application.get_env(:weather_client, :base_url, @default_base_url)
      end)

    timeout = Keyword.get(opts, :timeout, @default_timeout)
    req_options = Keyword.get(opts, :req_options, [])

    [
      base_url: base_url,
      headers: [{"x-api-key", api_key}],
      receive_timeout: timeout
    ]
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  @doc """
  Fetches the current forecast for the given coordinates.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%Req.Request{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    case Req.get(client, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, Forecast.from_map(body)}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, %Error{reason: :invalid_response, status: 200, message: inspect(body)}}

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

  @doc false
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      temperature_c: map["temperature_c"],
      condition: map["condition"],
      wind_kph: map["wind_kph"]
    }
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned (or raised) by `WeatherClient`.

  `:reason` is one of:

    * `:api_error` - the API answered with a 4xx/5xx status; see `:status`
      and `:message`.
    * `:invalid_response` - a 200 response with an unexpected body.
    * `:transport` - the request failed before a response arrived (timeout,
      connection refused, ...); `:message` describes the cause.
  """

  defexception [:reason, :status, :message]

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :transport,
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

defmodule WeatherClient do
  @moduledoc """
  Client for the `/forecast` endpoint of a public weather HTTP API.

  ## Configuration

      config :weather_client,
        api_key: "your-api-key",
        base_url: "https://weather.example.com",
        timeout: 5_000

  Every setting can also be passed per call to `forecast/3`, which takes
  precedence over the application environment.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://weather.example.com"
  @default_timeout 5_000

  @doc """
  Fetches the current forecast for the given coordinates.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header
    * `:base_url` - the base URL of the weather API
    * `:timeout` - the receive timeout in milliseconds

  ## Examples

      iex> WeatherClient.forecast(51.5, -0.12, api_key: "key")
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) do
    case setting(opts, :api_key) do
      nil ->
        {:error, %Error{type: :missing_api_key, message: "no API key configured"}}

      api_key ->
        request(lat, lon, api_key, opts)
    end
  end

  defp request(lat, lon, api_key, opts) do
    req_opts = [
      base_url: setting(opts, :base_url, @default_base_url),
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", api_key}],
      receive_timeout: setting(opts, :timeout, @default_timeout)
    ]

    case Req.get("/forecast", req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Forecast.parse(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.from_response(status, body)}

      {:error, exception} ->
        {:error, %Error{type: :transport, message: Exception.message(exception)}}
    end
  end

  defp setting(opts, key, default \\ nil) do
    Keyword.get_lazy(opts, key, fn ->
      Application.get_env(:weather_client, key, default)
    end)
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec parse(map() | binary()) :: {:ok, t()} | {:error, WeatherClient.Error.t()}
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, _} -> invalid_response(body)
    end
  end

  def parse(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind} = body)
      when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def parse(body), do: invalid_response(body)

  defp invalid_response(body) do
    {:error,
     %WeatherClient.Error{
       type: :invalid_response,
       message: "unexpected response body: #{inspect(body)}"
     }}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient.forecast/3`.

    * `:type` - one of `:missing_api_key`, `:api_error`, `:transport`,
      or `:invalid_response`
    * `:status` - the HTTP status, set for `:api_error` only
    * `:message` - a human-readable description
  """

  defstruct [:type, :status, :message]

  @type t :: %__MODULE__{
          type: :missing_api_key | :api_error | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t()
        }

  @doc false
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, %{"error" => message}) when is_binary(message) do
    %__MODULE__{type: :api_error, status: status, message: message}
  end

  def from_response(status, body) do
    %__MODULE__{
      type: :api_error,
      status: status,
      message: "HTTP #{status}: #{inspect(body)}"
    }
  end
end

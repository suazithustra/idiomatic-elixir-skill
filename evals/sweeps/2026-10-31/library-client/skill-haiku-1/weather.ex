defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API.

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
  """

  defmodule Error do
    @moduledoc """
    Error returned by `WeatherClient` functions.

    `kind` is `:api` when the server answers with a non-2xx status,
    `:transport` when no answer arrives (for example a timeout), and
    `:invalid_response` when a 2xx body lacks the expected fields.
    """

    @type t :: %__MODULE__{
            kind: :api | :transport | :invalid_response,
            status: non_neg_integer() | nil,
            message: String.t()
          }

    defexception [:kind, :status, :message]
  end

  defmodule Forecast do
    @moduledoc "Current weather for one location."

    @enforce_keys [:temperature_c, :condition, :wind_kph]
    defstruct [:temperature_c, :condition, :wind_kph]

    @type t :: %__MODULE__{
            temperature_c: number(),
            condition: String.t(),
            wind_kph: number()
          }
  end

  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct [:api_key, base_url: @default_base_url, timeout: @default_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - root URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `#{@default_timeout}`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [:api_key, base_url: @default_base_url, timeout: @default_timeout])

    %__MODULE__{
      api_key: Keyword.fetch!(opts, :api_key),
      base_url: opts[:base_url],
      timeout: opts[:timeout]
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  ## Examples

      {:ok, %WeatherClient.Forecast{}} = WeatherClient.forecast(client, 52.52, 13.41)
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, body} <- get(client, "/forecast", lat: lat, lon: lon) do
      parse_forecast(body)
    end
  end

  defp get(%__MODULE__{} = client, path, params) do
    req =
      Req.new(
        base_url: client.base_url,
        receive_timeout: client.timeout,
        headers: [{"x-api-key", client.api_key}]
      )

    case Req.get(req, url: path, params: params) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, api_error(status, body)}

      {:error, exception} ->
        {:error, %Error{kind: :transport, message: Exception.message(exception)}}
    end
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{kind: :api, status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{kind: :api, status: status, message: "request failed with status #{status}"}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp parse_forecast(_body) do
    {:error, %Error{kind: :invalid_response, message: "unexpected response body"}}
  end
end

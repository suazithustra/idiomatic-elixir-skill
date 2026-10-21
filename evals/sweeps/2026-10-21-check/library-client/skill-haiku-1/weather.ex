defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Create a client with `new/1`, then ask it for forecasts:

      client = WeatherClient.new(api_key: "my-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  Every client holds its own settings, so one application can talk to
  several endpoints or use different timeouts at the same time.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout]
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - root URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `#{@default_timeout}`.

  Raises `ArgumentError` when an option is missing or has the wrong type.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [:api_key, base_url: @default_base_url, timeout: @default_timeout])

    %__MODULE__{
      api_key: validate_api_key!(opts[:api_key]),
      base_url: validate_base_url!(opts[:base_url]),
      timeout: validate_timeout!(opts[:timeout])
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the API returns an error status,
  the request fails, or the response body has an unexpected shape.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    client
    |> build_request(lat, lon)
    |> Req.get()
    |> handle_response()
  end

  defp validate_api_key!(key) when is_binary(key) and key != "", do: key

  # The key is left out of the message on purpose: a bad value may still be a secret.
  defp validate_api_key!(_key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp validate_base_url!(url) when is_binary(url), do: String.trim_trailing(url, "/")

  defp validate_base_url!(url) do
    raise ArgumentError, "expected :base_url to be a string, got: #{inspect(url)}"
  end

  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout!(timeout) do
    raise ArgumentError, "expected :timeout to be a positive integer, got: #{inspect(timeout)}"
  end

  defp build_request(client, lat, lon) do
    Req.new(
      url: client.base_url <> "/forecast",
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    )
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    parse_forecast(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when is_binary(message) do
    {:error, %Error{status: status, message: message}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, %Error{status: status, message: "unexpected HTTP status"}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{message: "request failed", cause: exception}}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature,
         "condition" => condition,
         "wind_kph" => wind
       })
       when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(_body) do
    {:error, %Error{status: 200, message: "unexpected response body"}}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  Current weather for one location.

    * `:temperature_c` - temperature in degrees Celsius.
    * `:condition` - short description, such as `"cloudy"`.
    * `:wind_kph` - wind speed in kilometres per hour.
  """

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
  Reason returned when a forecast request fails.

    * `:status` - HTTP status code, or `nil` when no response was received.
    * `:message` - text for display.
    * `:cause` - the underlying exception for transport failures, otherwise `nil`.
  """

  defexception [:status, :message, :cause]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          message: String.t(),
          cause: Exception.t() | nil
        }
end

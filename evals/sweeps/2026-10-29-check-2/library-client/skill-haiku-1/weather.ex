defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast API.

      client = WeatherClient.new(api_key: "my-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  Failed calls return `{:error, %WeatherClient.Error{}}`.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_timeout 5_000
  @options [:api_key, base_url: @default_base_url, timeout: @default_timeout]

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
    opts = Keyword.validate!(opts, @options)
    client = struct!(__MODULE__, opts)

    if is_binary(client.api_key) do
      client
    else
      raise ArgumentError, "expected :api_key to be a string, got: #{inspect(client.api_key)}"
    end
  end

  @doc """
  Fetches the current forecast for a location.

  Latitude must be between -90 and 90, longitude between -180 and 180.
  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    client
    |> build_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  defp build_request(%__MODULE__{} = client) do
    Req.new(
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    )
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: parse_forecast(body)

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, api_error(status, body)}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{message: Exception.message(exception)}}
  end

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(body) do
    {:error, %Error{status: 200, message: "unexpected response body: #{inspect(body)}"}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{status: status, message: message}
  end

  defp api_error(status, body) do
    %Error{status: status, message: "unexpected error body: #{inspect(body)}"}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location, as returned by `WeatherClient.forecast/3`.
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
  A failed request. `status` is the HTTP status when the API answered, and
  `nil` when the request never got a response (connection or timeout error).
  """

  defexception [:status, :message]
end

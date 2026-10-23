defmodule WeatherClient do
  @moduledoc """
  Client for a weather forecast HTTP API.

  Build a client with `new/1`, then ask it for forecasts with `forecast/3`.

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder host; replace with the API's real base URL.
  @default_base_url "https://api.weather.example"
  @default_timeout :timer.seconds(15)
  @options [:api_key, base_url: @default_base_url, timeout: @default_timeout]

  defguardp is_latitude(lat) when is_number(lat) and lat >= -90 and lat <= 90
  defguardp is_longitude(lon) when is_number(lon) and lon >= -180 and lon <= 180

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout]
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{api_key: String.t(), base_url: String.t(), timeout: pos_integer()}

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header of every request.
    * `:base_url` - the API's base URL. Defaults to `"#{@default_base_url}"`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to `15000`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, @options)

    build(
      Keyword.fetch!(opts, :api_key),
      Keyword.fetch!(opts, :base_url),
      Keyword.fetch!(opts, :timeout)
    )
  end

  @doc """
  Fetches the current forecast for a coordinate.

  Latitude must be between -90 and 90, longitude between -180 and 180.
  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_latitude(lat) and is_longitude(lon) do
    client
    |> send_request(lat, lon)
    |> handle_response()
  end

  defp build(api_key, base_url, timeout)
       when is_binary(api_key) and is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout}
  end

  defp send_request(client, lat, lon) do
    request =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    Req.get(request, url: "/forecast", params: [lat: lat, lon: lon])
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: parse_forecast(body)

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when is_binary(message) do
    {:error, %Error{status: status, reason: message}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{status: status, reason: {:unexpected_body, body}}}
  end

  defp handle_response({:error, exception}), do: {:error, %Error{reason: exception}}

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(body), do: {:error, %Error{status: 200, reason: {:unexpected_body, body}}}
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A current forecast for one coordinate.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{temperature_c: number(), condition: String.t(), wind_kph: number()}
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient`.

  `:status` is the HTTP status, or `nil` when no response arrived. `:reason` is the
  API's `"error"` message, `{:unexpected_body, body}` for a response that does not
  match the forecast shape, or the transport exception.
  """

  defexception [:status, :reason]

  @type t :: %__MODULE__{status: pos_integer() | nil, reason: term()}

  @impl true
  def message(%__MODULE__{status: nil, reason: exception}) do
    "request failed: " <> Exception.message(exception)
  end

  def message(%__MODULE__{status: status, reason: reason}) when is_binary(reason) do
    "HTTP #{status}: #{reason}"
  end

  def message(%__MODULE__{status: status, reason: reason}) do
    "HTTP #{status}: #{inspect(reason)}"
  end
end

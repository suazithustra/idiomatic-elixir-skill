defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient`.

  `status` is the HTTP status code, or `nil` when no response arrived,
  for example on a timeout or a connection failure.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{status: non_neg_integer() | nil, message: String.t()}
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast for one location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  Build a client once with `new/2`, then call `forecast/3` with it. Each
  client holds its own API key, base URL and timeout, so one program can
  talk to two servers or use two keys.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://weather.example.com"
  @default_timeout 10_000

  # The API key is left out of `inspect/1` so it does not reach logs or
  # crash reports.
  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, base_url: @default_base_url, timeout: @default_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client for the API key `api_key`.

  ## Options

    * `:base_url` - the server to call. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.

  ## Examples

      iex> client = WeatherClient.new("test-key", timeout: 5_000)
      iex> client.timeout
      5000
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) do
    opts = Keyword.validate!(opts, base_url: @default_base_url, timeout: @default_timeout)
    base_url = Keyword.fetch!(opts, :base_url)
    timeout = check_timeout(Keyword.fetch!(opts, :timeout))

    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout}
  end

  @doc """
  Fetches the forecast for a latitude and longitude in decimal degrees.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the request fails or the server
  answers with an error.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> build_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  defp build_request(client) do
    Req.new(
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    )
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    parse_forecast(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, api_error(status, body)}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{message: Exception.message(exception)}}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok,
     %Forecast{
       temperature_c: temperature_c,
       condition: condition,
       wind_kph: wind_kph
     }}
  end

  defp parse_forecast(_body) do
    {:error, %Error{message: "unexpected forecast response"}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{status: status, message: "HTTP #{status} without an error message"}
  end

  defp check_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
end

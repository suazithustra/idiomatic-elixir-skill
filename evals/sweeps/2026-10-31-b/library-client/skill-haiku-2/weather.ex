defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location, as returned by `WeatherClient.forecast/3`.

  `temperature_c` is in degrees Celsius, `wind_kph` in kilometres per hour.
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
  An error the weather API returned, or a response whose body had an unexpected shape.

  `status` is the HTTP status code of the response.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{status: non_neg_integer(), message: String.t()}
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  Build a client with `new/1`, then ask it for a forecast with `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  Every request sends the key in the `x-api-key` header.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder: replace with the real API origin.
  @default_base_url "https://api.example.com"
  @default_timeout :timer.seconds(10)

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

    * `:api_key` - required. Sent in the `x-api-key` header of every request.
    * `:base_url` - the API origin, with scheme and host and no path, such as
      `"https://api.example.com"`. Defaults to `"#{@default_base_url}"`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults
      to `#{@default_timeout}`.

  Raises `KeyError` when `:api_key` is missing and `ArgumentError` when an
  option has the wrong type.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", timeout: 2_000)
      iex> client.timeout
      2000
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:api_key, :base_url, :timeout])
    client = struct!(__MODULE__, opts)
    check_options!(client)
  end

  @doc """
  Fetches the forecast at a latitude and longitude, in decimal degrees.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success. On failure it returns
  `{:error, exception}`: a `WeatherClient.Error` when the API answered with an
  error or an unexpected body, or a Req exception such as `Req.TransportError`
  when no answer arrived.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Exception.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, response} <- get_forecast(client, lat, lon),
         {:ok, forecast} <- parse_response(response) do
      {:ok, forecast}
    end
  end

  defp check_options!(%__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout} = client)
       when is_binary(api_key) and is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    client
  end

  defp check_options!(_client) do
    raise ArgumentError,
          ":api_key and :base_url must be strings, and :timeout a positive integer"
  end

  defp get_forecast(%__MODULE__{} = client, lat, lon) do
    request =
      Req.new(
        base_url: client.base_url,
        receive_timeout: client.timeout,
        headers: [{"x-api-key", client.api_key}]
      )

    Req.get(request, url: "/forecast", params: [lat: lat, lon: lon])
  end

  defp parse_response(%Req.Response{status: 200, body: body}), do: parse_forecast(body)

  defp parse_response(%Req.Response{status: status, body: body}) do
    {:error, error_from_body(status, body)}
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
    {:error, %Error{status: 200, message: "unexpected response body"}}
  end

  defp error_from_body(status, %{"error" => message}) when is_binary(message) do
    %Error{status: status, message: message}
  end

  defp error_from_body(status, _body) do
    %Error{status: status, message: "HTTP #{status}"}
  end
end

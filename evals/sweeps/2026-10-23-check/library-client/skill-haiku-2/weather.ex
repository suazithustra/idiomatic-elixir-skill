defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  Create a client once with `new/1`, then ask it for forecasts with `forecast/3`.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 15_000

  @derive {Inspect, except: [:req]}
  defstruct [:req]

  @typedoc "A configured client. Holds the API key, so its inspect output hides the request."
  @type t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - the API root. Defaults to `#{@default_base_url}`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `#{@default_timeout}`.

  Raises `KeyError` when `:api_key` is missing and `ArgumentError` for unknown options.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout
      ])

    build(Keyword.fetch!(opts, :api_key), opts[:base_url], opts[:timeout])
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the API rejects the request, the
  request cannot reach the API, or the response has an unexpected shape.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    req
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  defp build(api_key, base_url, timeout)
       when is_binary(api_key) and api_key != "" and is_binary(base_url) and
              is_integer(timeout) and timeout > 0 do
    req =
      Req.new(
        base_url: base_url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout
      )

    %__MODULE__{req: req}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    parse_forecast(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, api_error(status, body)}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{kind: :transport, message: Exception.message(exception)}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{kind: :api, status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{kind: :api, status: status, message: "HTTP #{status}"}
  end

  defp parse_forecast(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
       when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(body) do
    {:error, %Error{kind: :invalid_response, message: "unexpected response body: #{inspect(body)}"}}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast for one location."

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
  An error from `WeatherClient.forecast/3`.

  `kind` is one of:

    * `:api` - the API answered with a non-2xx status. `status` and `message` come from the response.
    * `:transport` - the request did not complete (connection, DNS, timeout). `message` describes it.
    * `:invalid_response` - the API answered 2xx with a body that is not a forecast.
  """

  defexception [:kind, :status, :message]

  @type t :: %__MODULE__{
          kind: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t()
        }
end

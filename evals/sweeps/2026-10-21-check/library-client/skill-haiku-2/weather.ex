defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast API.

  Build a client with `new/1`, then fetch a forecast with `forecast/3`:

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  Every request sends the key in the `x-api-key` header.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 15_000

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :timeout]

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
    * `:timeout` - milliseconds to wait for a response. Defaults to `#{@default_timeout}`.

  Raises `KeyError` when `:api_key` is missing and `ArgumentError` when an
  option has the wrong type. These are caller mistakes, so they raise.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout
      ])

    %__MODULE__{
      api_key: validate_api_key!(Keyword.fetch!(opts, :api_key)),
      base_url: validate_base_url!(opts[:base_url]),
      timeout: validate_timeout!(opts[:timeout])
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success and
  `{:error, %WeatherClient.Error{}}` on failure.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> get("/forecast", lat: lat, lon: lon)
    |> handle_forecast()
  end

  defp get(%__MODULE__{} = client, path, params) do
    req =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    Req.get(req, url: path, params: params)
  end

  defp handle_forecast({:ok, %Req.Response{status: 200, body: body}}) do
    parse_forecast(body)
  end

  defp handle_forecast({:ok, %Req.Response{status: status, body: body}}) do
    {:error, api_error(status, body)}
  end

  defp handle_forecast({:error, exception}) do
    {:error, %Error{kind: :transport, message: Exception.message(exception)}}
  end

  defp parse_forecast(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
       when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(_body) do
    {:error,
     %Error{kind: :invalid_response, message: "forecast response has missing or invalid fields"}}
  end

  defp api_error(status, %{"error" => message}) when is_binary(message) do
    %Error{kind: :api, status: status, message: message}
  end

  defp api_error(status, _body) do
    %Error{kind: :api, status: status, message: "request failed with HTTP #{status}"}
  end

  defp validate_api_key!(api_key) when is_binary(api_key) and api_key != "", do: api_key

  defp validate_api_key!(_api_key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp validate_base_url!(base_url) when is_binary(base_url) do
    String.trim_trailing(base_url, "/")
  end

  defp validate_base_url!(_base_url) do
    raise ArgumentError, "expected :base_url to be a string"
  end

  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout!(_timeout) do
    raise ArgumentError, "expected :timeout to be a positive integer (milliseconds)"
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
  An error returned by `WeatherClient`.

  `:kind` is one of:

    * `:api` - the server answered with a non-200 status. `:status` holds the
      HTTP status code and `:message` the `"error"` text from the body.
    * `:transport` - no usable answer arrived, such as a connection failure or
      a timeout. `:status` is `nil`.
    * `:invalid_response` - the server answered 200, but the body did not have
      the expected fields. `:status` is `nil`.
  """

  defexception [:kind, :status, :message]

  @type t :: %__MODULE__{
          kind: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t()
        }
end

defmodule WeatherClient do
  @moduledoc """
  Client for a weather HTTP API.

  Build a client with `new/1`, then ask it for a forecast:

      client = WeatherClient.new(api_key: "my-key", base_url: "https://weather.example.com")
      {:ok, %WeatherClient.Forecast{}} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  @default_timeout 5_000

  @enforce_keys [:base_url, :api_key, :timeout]
  @derive {Inspect, except: [:api_key]}
  defstruct [:base_url, :api_key, :timeout]

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client from options.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - required. Root URL of the API, such as `"https://weather.example.com"`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `5000`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:api_key, :base_url, timeout: @default_timeout])

    %__MODULE__{
      api_key: Keyword.fetch!(opts, :api_key),
      base_url: Keyword.fetch!(opts, :base_url),
      timeout: opts[:timeout]
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the API returns an error,
  the request fails, or the response has an unexpected shape.
  """
  @spec forecast(t(), number(), number()) ::
          {:ok, WeatherClient.Forecast.t()} | {:error, WeatherClient.Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, body} <- get(client, "/forecast", lat: lat, lon: lon) do
      parse_forecast(body)
    end
  end

  defp get(client, path, params) do
    req =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    case Req.get(req, url: path, params: params) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %WeatherClient.Error{kind: :api, status: status, message: error_message(status, body)}}

      {:error, exception} ->
        {:error, %WeatherClient.Error{kind: :transport, message: Exception.message(exception)}}
    end
  end

  defp error_message(_status, %{"error" => message}) when is_binary(message), do: message
  defp error_message(status, _body), do: "HTTP #{status}"

  defp parse_forecast(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
       when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok,
     %WeatherClient.Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(_body) do
    {:error,
     %WeatherClient.Error{kind: :invalid_response, message: "unexpected forecast response"}}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A current forecast for one location.
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

    * `:api` - the server returned a 4xx or 5xx response. `:status` holds the HTTP status.
    * `:transport` - no response arrived, for example a refused connection or a timeout.
    * `:invalid_response` - the server responded, but the body had an unexpected shape.
  """

  defexception [:kind, :message, :status]

  @type t :: %__MODULE__{
          kind: :api | :transport | :invalid_response,
          message: String.t(),
          status: pos_integer() | nil
        }
end

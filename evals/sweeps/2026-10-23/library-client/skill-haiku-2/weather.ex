defmodule WeatherClient do
  @moduledoc """
  Client for the weather API's `/forecast` endpoint.

  Build a client once with `new/1`, then ask it for forecasts:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder host. Replace it with the API's real base URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_receive_timeout 15_000
  @option_defaults [base_url: @default_base_url, receive_timeout: @default_receive_timeout]

  # The key is a credential, so it must not appear in logs or IEx output.
  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, base_url: @default_base_url, receive_timeout: @default_receive_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - origin of the API. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for a response. Defaults to `15_000`.

  Raises `KeyError` when `:api_key` is missing and `ArgumentError` when an
  unknown option is given.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:api_key] ++ @option_defaults)

    %__MODULE__{
      api_key: Keyword.fetch!(opts, :api_key),
      base_url: opts[:base_url],
      receive_timeout: opts[:receive_timeout]
    }
  end

  @doc """
  Fetches the forecast for a latitude and longitude in decimal degrees.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the request fails or the server
  answers with an error.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, response} <- get_forecast(client, lat, lon),
         {:ok, body} <- handle_response(response) do
      Forecast.parse(body)
    end
  end

  defp get_forecast(client, lat, lon) do
    request = build_request(client)
    params = [lat: lat, lon: lon]

    case Req.get(request, url: "/forecast", params: params) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, transport_error(exception)}
    end
  end

  defp build_request(client) do
    options = [
      base_url: client.base_url,
      receive_timeout: client.receive_timeout,
      headers: [{"x-api-key", client.api_key}]
    ]

    Req.new(options)
  end

  defp handle_response(%Req.Response{status: status} = response) when status in 200..299 do
    {:ok, response.body}
  end

  defp handle_response(response) do
    {:error, %Error{status: response.status, message: error_message(response)}}
  end

  defp error_message(%Req.Response{body: %{"error" => message}}) when is_binary(message) do
    message
  end

  defp error_message(response) do
    "HTTP #{response.status}"
  end

  defp transport_error(exception) do
    %Error{message: Exception.message(exception), cause: exception}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location, as returned by `WeatherClient.forecast/3`.
  """

  alias WeatherClient.Error

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc """
  Builds a forecast from a decoded response body.

  Returns `{:error, %WeatherClient.Error{}}` when the body lacks a field or a
  field has the wrong type, so a change in the API shows up here rather than
  as a `nil` later on.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
      when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  def parse(_body), do: {:error, %Error{message: "unexpected forecast response"}}
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when a forecast request fails.

  `status` holds the HTTP status when the server answered, and is `nil` for
  connection and timeout failures. `cause` holds the underlying exception when
  there is one.
  """

  defexception [:message, :status, :cause]

  @type t :: %__MODULE__{
          message: String.t(),
          status: pos_integer() | nil,
          cause: Exception.t() | nil
        }
end

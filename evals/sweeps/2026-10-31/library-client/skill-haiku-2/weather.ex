defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient`.

  `kind` is `:api` when the server answered with a 4xx or 5xx status and an
  `"error"` message, `:transport` when no response arrived (for example a
  timeout), and `:invalid_response` when the response does not have the
  expected shape. `status` is set for `:api` and `:invalid_response`, and
  `cause` holds the Req exception for `:transport`.
  """

  defexception [:kind, :status, :message, :cause]

  @type t :: %__MODULE__{
          kind: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t(),
          cause: Exception.t() | nil
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc "Current weather for one location."

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
  Client for the weather forecast API.

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  Each client holds its own settings, so one application can use clients
  with different base URLs or timeouts.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://weather.example.com"
  @default_receive_timeout 15_000

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct [:api_key, base_url: @default_base_url, receive_timeout: @default_receive_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - origin of the API. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for a response. Defaults to
      `#{@default_receive_timeout}`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        receive_timeout: @default_receive_timeout
      ])

    build(Keyword.fetch!(opts, :api_key), opts[:base_url], opts[:receive_timeout])
  end

  @doc """
  Returns the current forecast at a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, response} <- get_forecast(client, lat, lon),
         {:ok, body} <- read_body(response) do
      parse_forecast(body)
    end
  end

  defp build(api_key, base_url, receive_timeout)
       when is_binary(api_key) and byte_size(api_key) > 0 and is_binary(base_url) and
              is_integer(receive_timeout) and receive_timeout > 0 do
    %__MODULE__{api_key: api_key, base_url: base_url, receive_timeout: receive_timeout}
  end

  defp get_forecast(client, lat, lon) do
    req =
      Req.new(
        base_url: client.base_url,
        receive_timeout: client.receive_timeout,
        headers: [{"x-api-key", client.api_key}]
      )

    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, exception} ->
        error = %Error{
          kind: :transport,
          message: Exception.message(exception),
          cause: exception
        }

        {:error, error}
    end
  end

  defp read_body(%Req.Response{status: 200, body: body}), do: {:ok, body}

  defp read_body(%Req.Response{status: status, body: %{"error" => message}})
       when status >= 400 do
    {:error, %Error{kind: :api, status: status, message: message}}
  end

  defp read_body(%Req.Response{status: status}) do
    {:error,
     %Error{
       kind: :invalid_response,
       status: status,
       message: "unexpected response status #{status}"
     }}
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
    {:error,
     %Error{kind: :invalid_response, message: "response does not match the forecast shape"}}
  end
end

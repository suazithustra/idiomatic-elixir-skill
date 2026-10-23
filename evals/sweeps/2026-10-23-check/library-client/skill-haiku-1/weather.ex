defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Build a client once with `new/1`, then ask it for forecasts:

      client = WeatherClient.new(api_key: "my-key")
      {:ok, forecast} = WeatherClient.forecast(client, 51.5, -0.12)

  ## Options for `new/1`

    * `:api_key` - required. Sent in the `x-api-key` header of every request.
    * `:base_url` - root URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `#{@default_timeout}`.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder host: replace with the API's real root URL before publishing.
  @default_base_url "https://weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client from the options listed in the module docs.

  Raises `ArgumentError` when `:api_key` is missing or an option has the wrong type.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout
      ])

    build(opts[:api_key], opts[:base_url], opts[:timeout])
  end

  @doc """
  Fetches the forecast for a latitude and longitude in decimal degrees.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> build_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build(api_key, base_url, timeout)
       when is_binary(api_key) and is_binary(base_url) and is_integer(timeout) and timeout > 0 do
    %__MODULE__{
      api_key: api_key,
      base_url: String.trim_trailing(base_url, "/"),
      timeout: timeout
    }
  end

  defp build(_api_key, _base_url, _timeout) do
    raise ArgumentError,
          "expected :api_key and :base_url to be strings and :timeout to be a positive integer, " <>
            "and :api_key to be given"
  end

  defp build_request(%__MODULE__{} = client) do
    headers = [{"x-api-key", client.api_key}]

    Req.new(base_url: client.base_url, receive_timeout: client.timeout, headers: headers)
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    case Forecast.from_map(body) do
      {:ok, _forecast} = ok -> ok
      {:error, _reason} -> {:error, Error.exception(reason: {:unexpected_response, 200})}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when status >= 400 do
    {:error, Error.exception(reason: {:api, status, message})}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, Error.exception(reason: {:unexpected_response, status})}
  end

  defp handle_response({:error, exception}) do
    {:error, Error.exception(reason: {:transport, exception})}
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

  @doc false
  @spec from_map(term()) :: {:ok, t()} | {:error, :invalid_body}
  def from_map(%{
        "temperature_c" => temperature_c,
        "condition" => condition,
        "wind_kph" => wind_kph
      })
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok,
     %__MODULE__{
       temperature_c: temperature_c,
       condition: condition,
       wind_kph: wind_kph
     }}
  end

  def from_map(_body), do: {:error, :invalid_body}
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when a forecast request fails.

  The `:reason` field is one of:

    * `{:api, status, message}` - the API answered with a 4xx or 5xx status and an `"error"` message.
    * `{:unexpected_response, status}` - the API answered with a status or body this client does not expect.
    * `{:transport, exception}` - no answer arrived, for example a timeout or refused connection.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: term()}

  @impl true
  def message(%__MODULE__{reason: {:api, status, message}}) do
    "API error (HTTP #{status}): #{message}"
  end

  def message(%__MODULE__{reason: {:unexpected_response, status}}) do
    "unexpected response (HTTP #{status})"
  end

  def message(%__MODULE__{reason: {:transport, exception}}) do
    "request failed: #{Exception.message(exception)}"
  end
end

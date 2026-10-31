defmodule WeatherClient.Error do
  @moduledoc """
  The reason returned in `{:error, reason}` when a request fails.

  `:reason` is one of:

    * `:api_error` - the API answered with a non-2xx status. `:status` holds it.
    * `:invalid_response` - the API answered 2xx with a body of an unexpected shape.
    * `:transport` - the request never got a response (connection refused, timeout, ...).
  """

  defexception [:reason, :status, :message]

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :transport,
          status: non_neg_integer() | nil,
          message: String.t()
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_body(term()) :: {:ok, t()} | {:error, WeatherClient.Error.t()}
  def from_body(%{
        "temperature_c" => temperature_c,
        "condition" => condition,
        "wind_kph" => wind_kph
      })
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    forecast = %__MODULE__{
      temperature_c: temperature_c,
      condition: condition,
      wind_kph: wind_kph
    }

    {:ok, forecast}
  end

  def from_body(_body) do
    error = %WeatherClient.Error{
      reason: :invalid_response,
      message: "forecast response is missing temperature_c, condition or wind_kph"
    }

    {:error, error}
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client once with `new/2`, then pass it to `forecast/3`:

      client = WeatherClient.new("my-api-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)

  Nothing is read from the application environment, so one node can use
  several clients with different keys, base URLs or timeouts.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  defstruct [:api_key, :base_url, :timeout, :req_options]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: timeout(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, such as `plug:` for
      tests or `retry:`. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", timeout: 2_000)
      iex> client.timeout
      2000
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    build(api_key, opts[:base_url], opts[:timeout], opts[:req_options])
  end

  @doc """
  Fetches the forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the API answers with an error, the answer is malformed, or the request
  fails.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    req = build_request(client)

    req
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> parse_response()
  end

  @doc """
  Like `forecast/3`, but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} ->
        forecast

      {:error, error} ->
        raise error
    end
  end

  defp build(api_key, base_url, timeout, req_options)
       when is_binary(base_url) and is_list(req_options) and
              (timeout == :infinity or (is_integer(timeout) and timeout > 0)) do
    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      timeout: timeout,
      req_options: req_options
    }
  end

  defp build_request(client) do
    options = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]

    Req.new(Keyword.merge(options, client.req_options))
  end

  defp parse_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    Forecast.from_body(body)
  end

  defp parse_response({:ok, %Req.Response{status: status, body: body}}) do
    error = %Error{reason: :api_error, status: status, message: api_message(status, body)}
    {:error, error}
  end

  defp parse_response({:error, exception}) do
    error = %Error{reason: :transport, message: Exception.message(exception)}
    {:error, error}
  end

  defp api_message(_status, %{"error" => message}) when is_binary(message), do: message
  defp api_message(status, _body), do: "weather API returned status #{status}"
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather forecast HTTP API.

  Build a client with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, %WeatherClient.Forecast{}} = WeatherClient.forecast(client, 52.52, 13.40)

  Every setting is passed to `new/1`, so one application can hold several
  clients with different keys, base URLs, or timeouts.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_receive_timeout :timer.seconds(15)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :receive_timeout, :req_options]
  defstruct [:api_key, :base_url, :receive_timeout, :req_options]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  Raises `ArgumentError` if an option is missing, unknown, or has the wrong type.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header. Required.
    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.
    * `:receive_timeout` - milliseconds to wait for a response.
      Defaults to `#{@default_receive_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, such as
      `plug: {Req.Test, WeatherClient}` in tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", receive_timeout: 5_000)
      iex> client.receive_timeout
      5000

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        receive_timeout: @default_receive_timeout,
        req_options: []
      ])

    build(opts[:api_key], opts[:base_url], opts[:receive_timeout], opts[:req_options])
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, forecast}` or `{:error, %WeatherClient.Error{}}`. See
  `WeatherClient.Error` for the possible reasons.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    request_options = [url: "/forecast", params: [lat: lat, lon: lon]]

    case Req.get(req(client), request_options) do
      {:ok, response} -> handle_response(response)
      {:error, exception} -> {:error, %Error{reason: :transport_error, detail: exception}}
    end
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

  defp build(api_key, base_url, receive_timeout, req_options)
       when is_binary(api_key) and api_key != "" and is_binary(base_url) and
              is_integer(receive_timeout) and receive_timeout > 0 and is_list(req_options) do
    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      receive_timeout: receive_timeout,
      req_options: req_options
    }
  end

  defp build(api_key, base_url, receive_timeout, req_options) do
    invalid =
      [
        api_key: api_key,
        base_url: base_url,
        receive_timeout: receive_timeout,
        req_options: req_options
      ]
      |> Enum.reject(fn {name, value} -> valid_option?(name, value) end)
      |> Enum.map_join(", ", fn {name, value} -> "#{name}: #{inspect_option(name, value)}" end)

    raise ArgumentError, "invalid options for WeatherClient.new/1: #{invalid}"
  end

  defp valid_option?(:api_key, api_key), do: is_binary(api_key) and api_key != ""
  defp valid_option?(:base_url, base_url), do: is_binary(base_url)
  defp valid_option?(:receive_timeout, timeout), do: is_integer(timeout) and timeout > 0
  defp valid_option?(:req_options, req_options), do: is_list(req_options)

  # The key itself must not end up in an exception message or a log.
  defp inspect_option(:api_key, nil), do: "missing"
  defp inspect_option(:api_key, ""), do: "empty string"
  defp inspect_option(:api_key, _api_key), do: "expected a string"
  defp inspect_option(_name, value), do: inspect(value)

  defp req(client) do
    base_options = [
      base_url: client.base_url,
      receive_timeout: client.receive_timeout,
      headers: [{"x-api-key", client.api_key}]
    ]

    base_options
    |> Keyword.merge(client.req_options)
    |> Req.new()
  end

  defp handle_response(%Req.Response{status: 200, body: body}) do
    case Forecast.parse(body) do
      {:ok, forecast} -> {:ok, forecast}
      :error -> {:error, %Error{reason: :invalid_response, status: 200, detail: body}}
    end
  end

  defp handle_response(%Req.Response{status: status, body: %{"error" => message}})
       when status in 400..599 and is_binary(message) do
    {:error, %Error{reason: :api_error, status: status, detail: message}}
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    {:error, %Error{reason: :invalid_response, status: status, detail: body}}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    forecast = %__MODULE__{
      temperature_c: temperature_c,
      condition: condition,
      wind_kph: wind_kph
    }

    {:ok, forecast}
  end

  def parse(_body), do: :error
end

defmodule WeatherClient.Error do
  @moduledoc """
  The error returned by `WeatherClient.forecast/3` and raised by
  `WeatherClient.forecast!/3`.

  The `:reason` field is one of:

    * `:api_error` - the API answered with a 4xx or 5xx status and an error
      message. `:status` holds the status and `:detail` the message.
    * `:invalid_response` - the API answered with a body this client does not
      understand. `:status` holds the status and `:detail` the body.
    * `:transport_error` - the request did not complete, for example because of a
      timeout or a refused connection. `:detail` holds the exception from Req.
  """

  defexception [:reason, :status, :detail]

  @type reason :: :api_error | :invalid_response | :transport_error

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          detail: term()
        }

  @impl true
  def message(%__MODULE__{reason: :api_error} = error) do
    "weather API returned status #{error.status}: #{error.detail}"
  end

  def message(%__MODULE__{reason: :invalid_response} = error) do
    "weather API returned an unexpected response with status #{error.status}: " <>
      inspect(error.detail)
  end

  def message(%__MODULE__{reason: :transport_error} = error) do
    "weather API request failed: " <> Exception.message(error.detail)
  end
end

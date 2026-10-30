defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

  Build a client once with `new/2` and pass it to `fetch_forecast/3`. Nothing is
  read from the application environment, so one node can hold several clients
  with different keys, base URLs or timeouts.

  ## Examples

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, forecast} = WeatherClient.fetch_forecast(client, 52.52, 13.4)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct [:api_key, :req_options, base_url: @default_base_url, timeout: @default_timeout]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: timeout(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:base_url` - base URL of the API. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds or
      `:infinity`. Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options merged into the `Req` request, for example
      `plug:` in tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", base_url: "http://localhost:4000")
      iex> client.base_url
      "http://localhost:4000"
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    defaults = [base_url: @default_base_url, timeout: @default_timeout, req_options: []]
    opts = Keyword.validate!(opts, defaults)

    %__MODULE__{
      api_key: api_key,
      base_url: base_url!(opts[:base_url]),
      timeout: timeout!(opts[:timeout]),
      req_options: req_options!(opts[:req_options])
    }
  end

  @doc """
  Fetches the current forecast for a coordinate.

  Returns `{:error, %WeatherClient.Error{}}` when the API answers with an error
  status, the request fails, or the response body is not a forecast.
  """
  @spec fetch_forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def fetch_forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lon) and lon >= -180 and
             lon <= 180 do
    with {:ok, body} <- request(client, lat, lon) do
      Forecast.from_body(body)
    end
  end

  @doc """
  Same as `fetch_forecast/3`, but raises the `WeatherClient.Error`.
  """
  @spec fetch_forecast!(t(), number(), number()) :: Forecast.t()
  def fetch_forecast!(%__MODULE__{} = client, lat, lon) do
    case fetch_forecast(client, lat, lon) do
      {:ok, forecast} ->
        forecast

      {:error, error} ->
        raise error
    end
  end

  defp request(client, lat, lon) do
    req = build_request(client)

    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{} = response} ->
        {:error, api_error(response)}

      {:error, exception} ->
        {:error, %Error{reason: :transport, detail: Exception.message(exception)}}
    end
  end

  defp build_request(client) do
    options = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]

    Req.merge(Req.new(options), client.req_options)
  end

  defp api_error(%Req.Response{status: status, body: %{"error" => detail}})
       when is_binary(detail) do
    %Error{reason: :api_error, status: status, detail: detail}
  end

  defp api_error(%Req.Response{status: status}) do
    %Error{reason: :api_error, status: status}
  end

  defp base_url!(base_url) when is_binary(base_url) and base_url != "", do: base_url

  defp timeout!(:infinity), do: :infinity
  defp timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp req_options!(req_options) when is_list(req_options), do: req_options
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast as returned by `GET /forecast`.
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
  Builds a forecast from the decoded JSON body of the API.

  ## Examples

      iex> body = %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12}
      iex> WeatherClient.Forecast.from_body(body)
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

      iex> WeatherClient.Forecast.from_body(%{"temperature_c" => "warm"})
      {:error, %WeatherClient.Error{reason: :invalid_response}}
  """
  @spec from_body(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_body(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    forecast = %__MODULE__{
      temperature_c: temperature_c,
      condition: condition,
      wind_kph: wind_kph
    }

    {:ok, forecast}
  end

  def from_body(_body), do: {:error, %Error{reason: :invalid_response}}
end

defmodule WeatherClient.Error do
  @moduledoc """
  Reason returned in `{:error, error}` by `WeatherClient`.

  `:reason` is one of:

    * `:api_error` - the API answered with a 4xx or 5xx `:status`; `:detail` holds
      the API's `"error"` text when the body had one.
    * `:transport` - the request failed before a response arrived; `:detail`
      holds the underlying error message.
    * `:invalid_response` - the API answered 2xx with a body that is not a forecast.
  """

  defexception [:reason, :status, :detail]

  @type t :: %__MODULE__{
          reason: :api_error | :transport | :invalid_response,
          status: pos_integer() | nil,
          detail: String.t() | nil
        }

  @impl Exception
  def message(%__MODULE__{reason: :api_error, status: status, detail: nil}) do
    "weather API returned status #{status}"
  end

  def message(%__MODULE__{reason: :api_error, status: status, detail: detail}) do
    "weather API returned status #{status}: #{detail}"
  end

  def message(%__MODULE__{reason: :transport, detail: detail}) do
    "weather API request failed: #{detail}"
  end

  def message(%__MODULE__{reason: :invalid_response}) do
    "weather API returned a body that is not a forecast"
  end
end

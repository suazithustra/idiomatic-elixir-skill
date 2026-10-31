defmodule WeatherClient.Error do
  @moduledoc """
  The reason in every `{:error, reason}` returned by `WeatherClient`.

  `reason` is one of:

    * `{:http_status, status}` - the API answered with a non-2xx status;
      `message` is the API's `"error"` text when it sent one.
    * `{:request_failed, exception}` - no response arrived, for example a
      timeout or a refused connection; `exception` is the one `Req` returned.
    * `{:invalid_response, body}` - a 2xx response whose body is not a forecast.
  """

  defexception [:reason, :message]

  @type t :: %__MODULE__{
          reason:
            {:http_status, non_neg_integer()}
            | {:request_failed, Exception.t()}
            | {:invalid_response, term()},
          message: String.t()
        }
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast as returned by `WeatherClient.fetch_forecast/3`.

  `condition` is the API's own text (for example `"cloudy"`); it is not
  converted to an atom because the API may add new values.
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
      iex> WeatherClient.Forecast.parse(body)
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

      iex> {:error, error} = WeatherClient.Forecast.parse(%{"temperature_c" => 21.5})
      iex> error.reason
      {:invalid_response, %{"temperature_c" => 21.5}}
  """
  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def parse(body) do
    message = "the API returned an unexpected body"
    {:error, %Error{reason: {:invalid_response, body}, message: message}}
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API, built on `Req`.

  Build a client once with `new/2`, then pass it to `fetch_forecast/3`:

      client = WeatherClient.new(System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.fetch_forecast(client, 52.52, 13.4)

  The client reads nothing from the application environment, so two clients
  with different keys or base URLs can be used side by side.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout]
  defstruct [:api_key, :base_url, :timeout, req_options: []]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.get/1`, for example
      `retry: false` or `plug: {Req.Test, WeatherClient}` in tests. They
      override the options set by this client. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", timeout: 2_000)
      iex> client.timeout
      2000

      iex> inspect(WeatherClient.new("secret")) =~ "secret"
      false
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    client = %__MODULE__{
      api_key: api_key,
      base_url: opts[:base_url],
      timeout: opts[:timeout],
      req_options: opts[:req_options]
    }

    validate_options(client)
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:error, %WeatherClient.Error{}}` when the request fails, the API
  answers with an error status, or the body is not a forecast.
  """
  @spec fetch_forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def fetch_forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    options = [
      base_url: client.base_url,
      url: "/forecast",
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]

    options
    |> Keyword.merge(client.req_options)
    |> Req.get()
    |> handle_response()
  end

  @doc """
  Same as `fetch_forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
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

  defp validate_options(%__MODULE__{} = client)
       when is_binary(client.base_url) and is_integer(client.timeout) and client.timeout > 0 and
              is_list(client.req_options) do
    client
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    Forecast.parse(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: {:http_status, status}, message: error_message(status, body)}}
  end

  defp handle_response({:error, exception}) do
    message = "request failed: " <> Exception.message(exception)
    {:error, %Error{reason: {:request_failed, exception}, message: message}}
  end

  defp error_message(_status, %{"error" => message}) when is_binary(message), do: message
  defp error_message(status, _body), do: "the API answered with status #{status}"
end

# WeatherClient builds the structs below at compile time, so in a single file they come first.

defmodule WeatherClient.Forecast do
  @moduledoc """
  The forecast for one location.

  `:condition` is the API's own text, such as `"cloudy"`. It stays a string because the
  API may add conditions this library does not know about.
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
  def parse(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
      when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  def parse(_body), do: :error
end

defmodule WeatherClient.Error do
  @moduledoc """
  Why a request failed, returned as `{:error, %WeatherClient.Error{}}`.

  `:reason` says what went wrong:

    * `:api_error` - the API answered with a status other than 200. `:status` holds the
      status, `:api_message` the text of the body's `"error"` field when it has one, and
      `:body` the response body.
    * `:invalid_response` - the API answered 200, but the body in `:body` is not a forecast.
    * `:request_failed` - `Req` returned an error instead of a response, for example on a
      timeout or a refused connection. `:exception` holds that error, such as a
      `Req.TransportError`.
  """

  @enforce_keys [:reason]
  defexception [:reason, :status, :api_message, :body, :exception]

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :request_failed,
          status: pos_integer() | nil,
          api_message: String.t() | nil,
          body: term(),
          exception: Exception.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, api_message: nil} = error) do
    "weather API responded with status #{error.status}"
  end

  def message(%__MODULE__{reason: :api_error} = error) do
    "weather API responded with status #{error.status}: #{error.api_message}"
  end

  def message(%__MODULE__{reason: :invalid_response} = error) do
    "weather API returned a body that is not a forecast: #{inspect(error.body)}"
  end

  def message(%__MODULE__{reason: :request_failed} = error) do
    "request to the weather API failed: #{Exception.message(error.exception)}"
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather forecast API.

  Build a client once with `new/1` and pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))

      case WeatherClient.forecast(client, 52.52, 13.41) do
        {:ok, forecast} -> forecast.temperature_c
        {:error, error} -> Exception.message(error)
      end

  The client struct hides the API key when inspected, so it stays out of logs and crash
  reports.

  ## Testing

  `:req_options` is passed to `Req`, so tests can stub the API with `Req.Test`:

      client = WeatherClient.new(api_key: "test", req_options: [plug: {Req.Test, WeatherClient}])

      Req.Test.stub(WeatherClient, fn conn ->
        Req.Test.json(conn, %{"temperature_c" => 21.5, "condition" => "cloudy", "wind_kph" => 12})
      end)
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(15)
  @option_defaults [base_url: @default_base_url, timeout: @default_timeout, req_options: []]

  @enforce_keys [:api_key, :base_url, :timeout]
  @derive {Inspect, except: [:api_key]}
  defstruct [:api_key, :base_url, :timeout, req_options: []]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  defguardp is_latitude(value) when is_number(value) and value >= -90 and value <= 90
  defguardp is_longitude(value) when is_number(value) and value >= -180 and value <= 180

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - the key sent in the `x-api-key` header of every request. Required.
    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.
    * `:timeout` - how long to wait for response data, in milliseconds, passed to `Req` as
      `:receive_timeout`. Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options for `Req.new/1`, merged over the ones above. Use it to
      stub the API in tests or to change `Req`'s retry behaviour. Defaults to `[]`.

  Raises `KeyError` when `:api_key` is missing, and `ArgumentError` when an option is
  unknown or has an invalid value.

  ## Examples

      iex> client = WeatherClient.new(api_key: "my-key", timeout: 5_000)
      iex> client.timeout
      5000

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:api_key | @option_defaults])

    %__MODULE__{
      api_key: validate_api_key(Keyword.fetch!(opts, :api_key)),
      base_url: validate_base_url(opts[:base_url]),
      timeout: validate_timeout(opts[:timeout]),
      req_options: validate_req_options(opts[:req_options])
    }
  end

  @doc """
  Fetches the forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}` when the
  API answers with an error or cannot be reached. `lat` must be a number from -90 to 90 and
  `lon` a number from -180 to 180.

  ## Examples

      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.condition
      #=> "cloudy"

  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_latitude(lat) and is_longitude(lon) do
    client
    |> new_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast itself and raises `WeatherClient.Error`
  on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp new_request(client) do
    options = [
      base_url: client.base_url,
      receive_timeout: client.timeout,
      headers: [{"x-api-key", client.api_key}]
    ]

    options
    |> Req.new()
    |> Req.merge(client.req_options)
  end

  defp handle_response({:ok, %Req.Response{status: 200} = response}) do
    case Forecast.parse(response.body) do
      {:ok, forecast} -> {:ok, forecast}
      :error -> {:error, %Error{reason: :invalid_response, status: 200, body: response.body}}
    end
  end

  defp handle_response({:ok, %Req.Response{} = response}) do
    error = %Error{
      reason: :api_error,
      status: response.status,
      api_message: api_message(response.body),
      body: response.body
    }

    {:error, error}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :request_failed, exception: exception}}
  end

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: nil

  defp validate_api_key(api_key) when is_binary(api_key) and api_key != "", do: api_key

  # The value is left out of the message so a mistyped key does not end up in logs.
  defp validate_api_key(_api_key) do
    raise ArgumentError, "expected :api_key to be a non-empty string"
  end

  defp validate_base_url(base_url) when is_binary(base_url) and base_url != "", do: base_url

  defp validate_base_url(base_url) do
    raise ArgumentError, "expected :base_url to be a non-empty string, got: #{inspect(base_url)}"
  end

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout(timeout) do
    raise ArgumentError, "expected :timeout to be a positive integer, got: #{inspect(timeout)}"
  end

  defp validate_req_options(req_options) when is_list(req_options), do: req_options

  defp validate_req_options(req_options) do
    raise ArgumentError, "expected :req_options to be a list, got: #{inspect(req_options)}"
  end
end

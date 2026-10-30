defmodule WeatherClient.Error do
  @moduledoc """
  Why a forecast request failed.

  `WeatherClient.forecast/3` returns this as `{:error, error}` and
  `WeatherClient.forecast!/3` raises it. The `:reason` field says what happened:

    * `:api_error` - the API answered with a status other than 200. `:status`
      holds that status and `:detail` the API's error text, or `nil` if the
      response carried none.

    * `:invalid_response` - the API answered 200, but the body is not a forecast.

    * `:request_failed` - no usable response arrived, for example after a
      timeout or a refused connection. `:cause` holds the exception from Req.

  """

  defexception [:reason, :status, :detail, :cause]

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :request_failed,
          status: pos_integer() | nil,
          detail: String.t() | nil,
          cause: Exception.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, detail: nil} = error) do
    "weather API answered with status #{error.status}"
  end

  def message(%__MODULE__{reason: :api_error} = error) do
    "weather API answered with status #{error.status}: #{error.detail}"
  end

  def message(%__MODULE__{reason: :invalid_response}) do
    "weather API answered with a body that is not a forecast"
  end

  def message(%__MODULE__{reason: :request_failed} = error) do
    "weather API request failed: #{Exception.message(error.cause)}"
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  The forecast for one location, returned by `WeatherClient.forecast/3`.

  `:condition` is the API's own text, such as `"cloudy"`. It stays a string so
  that a condition the API adds later does not need a new release of this package.
  """

  alias WeatherClient.Error

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def parse(_body), do: {:error, %Error{reason: :invalid_response}}
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Build a client with an API key and pass it to `forecast/3`:

      client = WeatherClient.new("my-api-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
      #=> 21.5

  A client holds all of its settings, so one system can use several clients with
  different keys. To keep the key in your application's configuration, read it
  where you build the client:

      WeatherClient.new(Application.fetch_env!(:my_app, :weather_api_key))

  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  # Placeholder: set this to the API's real host before publishing.
  @default_base_url "https://api.example.com"
  @default_timeout :timer.seconds(5)

  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  @derive {Inspect, only: [:base_url, :timeout]}
  defstruct [:api_key, :base_url, :timeout, :req_options]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @type option ::
          {:base_url, String.t()}
          | {:timeout, pos_integer()}
          | {:req_options, keyword()}

  @doc """
  Builds a client that sends `api_key` with every request.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.

    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`. The limit applies to each attempt, and Req retries
      a failed request up to three times, so a call can take longer.

    * `:req_options` - extra options for `Req`, which override the ones this
      package sets. Use it to stub the API in tests,
      `[plug: {Req.Test, MyApp.Weather}]`, or to turn off retries,
      `[retry: false]`. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("my-api-key", timeout: 2_000)
      iex> client.timeout
      2000

  """
  @spec new(String.t(), [option()]) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and api_key != "" do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    Enum.each(opts, &check_option/1)
    struct!(__MODULE__, [{:api_key, api_key} | opts])
  end

  @doc """
  Fetches the forecast for a latitude and longitude.

  Returns `{:ok, forecast}`, or `{:error, error}` with a `WeatherClient.Error`
  when the request fails or the API answers with an error.

  ## Examples

      iex> body = %{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}
      iex> stub = fn request -> {request, Req.Response.json(body)} end
      iex> client = WeatherClient.new("my-api-key", req_options: [adapter: stub])
      iex> WeatherClient.forecast(client, 52.52, 13.41)
      {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> build_request()
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Fetches a forecast like `forecast/3`, but returns it bare and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} ->
        forecast

      {:error, error} ->
        raise error
    end
  end

  # These clauses never receive the API key, so a bad option cannot put it in
  # the arguments of a FunctionClauseError, which end up in crash reports.
  defp check_option({:base_url, base_url}) when is_binary(base_url), do: :ok
  defp check_option({:timeout, timeout}) when is_integer(timeout) and timeout > 0, do: :ok
  defp check_option({:req_options, req_options}) when is_list(req_options), do: :ok

  defp build_request(%__MODULE__{} = client) do
    # When a redirect changes host, Req removes only the `authorization` header,
    # so following one would send `x-api-key` to that host.
    options = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout,
      redirect: false
    ]

    Req.merge(Req.new(options), client.req_options)
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    Forecast.parse(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :api_error, status: status, detail: error_detail(body)}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :request_failed, cause: exception}}
  end

  # A proxy in front of the API can answer with HTML or an empty body.
  defp error_detail(%{"error" => detail}) when is_binary(detail), do: detail
  defp error_detail(_body), do: nil
end

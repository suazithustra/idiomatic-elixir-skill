defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast for one location.

    * `:temperature_c` - the temperature in degrees Celsius.
    * `:condition` - the API's description of the sky, such as `"cloudy"`.
    * `:wind_kph` - the wind speed in kilometres per hour.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(term()) ::
          {:ok, t()}
          | {:error, {:missing_field, String.t()} | {:invalid_field, String.t()}}
          | {:error, {:unexpected_body, term()}}
  def from_map(%{} = body) do
    with {:ok, temperature_c} <- number_field(body, "temperature_c"),
         {:ok, condition} <- string_field(body, "condition"),
         {:ok, wind_kph} <- number_field(body, "wind_kph") do
      forecast = %__MODULE__{
        temperature_c: temperature_c,
        condition: condition,
        wind_kph: wind_kph
      }

      {:ok, forecast}
    end
  end

  def from_map(body), do: {:error, {:unexpected_body, body}}

  defp number_field(body, key) do
    case body do
      %{^key => value} when is_number(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp string_field(body, key) do
    case body do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  The error returned, or raised, when a forecast cannot be fetched.

  The `:reason` field says what went wrong, and `:details` holds the data for it:

    * `:request_failed` - the request did not get a response. `:details` is the
      exception from `Req`, such as a `Req.TransportError` for a timeout.

    * `:http_error` - the API answered with a non-2xx status, stored in `:status`.
      `:details` is the response body, usually `%{"error" => message}`.

    * `:invalid_response` - the API answered 2xx but the body is not a forecast.
      `:details` is `{:missing_field, key}`, `{:invalid_field, key}`, or
      `{:unexpected_body, body}`.
  """

  defexception [:reason, :status, :details]

  @type reason :: :request_failed | :http_error | :invalid_response

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          details: term()
        }

  @impl true
  def message(%__MODULE__{reason: :request_failed, details: exception}) do
    "weather API request failed: " <> Exception.message(exception)
  end

  def message(%__MODULE__{reason: :http_error, status: status, details: %{"error" => message}})
      when is_binary(message) do
    "weather API returned HTTP #{status}: #{message}"
  end

  def message(%__MODULE__{reason: :http_error, status: status}) do
    "weather API returned HTTP #{status}"
  end

  def message(%__MODULE__{reason: :invalid_response, details: details}) do
    "weather API returned an unexpected response: #{inspect(details)}"
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather forecast HTTP API, built on `Req`.

  Build a client once with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.condition
      #=> "cloudy"

  Failed calls return `{:error, %WeatherClient.Error{}}`, which you can match on
  or raise.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example"
  @default_receive_timeout :timer.seconds(15)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :receive_timeout]
  defstruct [:api_key, :base_url, :receive_timeout, req_options: []]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header. Required.

    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.

    * `:receive_timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_receive_timeout}`.

    * `:req_options` - extra options passed to `Req.new/1`, such as `:retry` or
      `:plug` for tests with `Req.Test`. They take precedence over the options
      above. Defaults to `[]`.

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

    %__MODULE__{
      api_key: validate_api_key(Keyword.fetch!(opts, :api_key)),
      base_url: validate_base_url(opts[:base_url]),
      receive_timeout: validate_receive_timeout(opts[:receive_timeout]),
      req_options: validate_req_options(opts[:req_options])
    }
  end

  @doc """
  Fetches the current forecast for a latitude and longitude, in decimal degrees.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the request fails, the API answers with an error status, or the response
  body is not a forecast.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, latitude, longitude)
      when is_number(latitude) and is_number(longitude) do
    with {:ok, response} <- request_forecast(client, latitude, longitude),
         {:ok, body} <- success_body(response) do
      parse_forecast(body)
    end
  end

  @doc """
  Like `forecast/3`, but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, latitude, longitude) do
    case forecast(client, latitude, longitude) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp request_forecast(client, latitude, longitude) do
    params = [lat: latitude, lon: longitude]

    case Req.get(new_request(client), url: "/forecast", params: params) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, %Error{reason: :request_failed, details: exception}}
    end
  end

  defp new_request(client) do
    request =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.receive_timeout
      )

    Req.merge(request, client.req_options)
  end

  defp success_body(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, body}
  end

  defp success_body(%Req.Response{status: status, body: body}) do
    {:error, %Error{reason: :http_error, status: status, details: body}}
  end

  defp parse_forecast(body) do
    case Forecast.from_map(body) do
      {:ok, forecast} -> {:ok, forecast}
      {:error, reason} -> {:error, %Error{reason: :invalid_response, details: reason}}
    end
  end

  defp validate_api_key(api_key) when is_binary(api_key) and api_key != "", do: api_key

  defp validate_api_key(api_key) do
    raise ArgumentError, ":api_key must be a non-empty string, got: #{inspect(api_key)}"
  end

  defp validate_base_url(base_url) when is_binary(base_url), do: base_url

  defp validate_base_url(base_url) do
    raise ArgumentError, ":base_url must be a string, got: #{inspect(base_url)}"
  end

  defp validate_receive_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_receive_timeout(timeout) do
    raise ArgumentError, ":receive_timeout must be a positive integer, got: #{inspect(timeout)}"
  end

  defp validate_req_options(req_options) when is_list(req_options), do: req_options

  defp validate_req_options(req_options) do
    raise ArgumentError, ":req_options must be a keyword list, got: #{inspect(req_options)}"
  end
end

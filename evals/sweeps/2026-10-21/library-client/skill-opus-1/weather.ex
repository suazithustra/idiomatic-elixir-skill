defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast for one location, as returned by `WeatherClient.forecast/3`.

    * `:temperature_c` - the temperature in degrees Celsius.
    * `:condition` - the API's description of the weather, such as `"cloudy"`.
    * `:wind_kph` - the wind speed in kilometres per hour.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  The error returned as `{:error, %WeatherClient.Error{}}` by `WeatherClient`
  functions and raised by the `!` variants.

  The `:reason` field says what went wrong, and the meaning of the other
  fields depends on it:

    * `:api_error` - the API responded with a 4xx or 5xx status. `:status`
      holds the status code and `:detail` the API's `"error"` text, or `nil`
      when the body had none.
    * `:unexpected_status` - the API responded with a status that is not
      2xx, 4xx, or 5xx. `:status` holds the status code.
    * `:invalid_response` - the API responded with a 2xx status, but the body
      was not a forecast. `:detail` is `{:missing_field, key}`,
      `{:invalid_field, key}`, or `:not_a_json_object`.
    * `:request_failed` - no response arrived, for example because of a
      timeout or a refused connection. `:detail` holds the exception returned
      by Req.
  """

  @enforce_keys [:reason]
  defexception [:reason, :status, :detail]

  @type t :: %__MODULE__{
          reason: :api_error | :unexpected_status | :invalid_response | :request_failed,
          status: non_neg_integer() | nil,
          detail:
            String.t()
            | {:missing_field, String.t()}
            | {:invalid_field, String.t()}
            | :not_a_json_object
            | Exception.t()
            | nil
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, detail: nil} = error) do
    "weather API responded with HTTP status #{error.status}"
  end

  def message(%__MODULE__{reason: :api_error} = error) do
    "weather API responded with HTTP status #{error.status}: #{error.detail}"
  end

  def message(%__MODULE__{reason: :unexpected_status} = error) do
    "weather API responded with unexpected HTTP status #{error.status}"
  end

  def message(%__MODULE__{reason: :invalid_response, detail: {:missing_field, key}}) do
    "weather API response is missing the #{inspect(key)} field"
  end

  def message(%__MODULE__{reason: :invalid_response, detail: {:invalid_field, key}}) do
    "weather API response has an invalid #{inspect(key)} field"
  end

  def message(%__MODULE__{reason: :invalid_response, detail: :not_a_json_object}) do
    "weather API response body is not a JSON object"
  end

  def message(%__MODULE__{reason: :request_failed} = error) do
    "request to weather API failed: " <> Exception.message(error.detail)
  end
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather API.

  Build a client with your API key, then request forecasts with it:

      client = WeatherClient.new(System.fetch_env!("WEATHER_API_KEY"))

      case WeatherClient.forecast(client, 52.52, 13.41) do
        {:ok, forecast} -> forecast.temperature_c
        {:error, error} -> Exception.message(error)
      end

  Failed requests return `{:error, %WeatherClient.Error{}}`. See
  `WeatherClient.Error` for the possible reasons.
  """

  alias WeatherClient.{Error, Forecast}

  # Placeholder: set this to the weather API's production URL before publishing.
  @default_base_url "https://api.weather.example"
  @default_timeout :timer.seconds(5)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client that sends `api_key` in the `x-api-key` header of every
  request.

  ## Options

    * `:base_url` - the URL of the API. Defaults to `#{inspect(@default_base_url)}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`. For example,
      `retry: false` turns off Req's retries of transient errors, and
      `plug: {Req.Test, MyStub}` stubs the API in tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("my-api-key", timeout: 2_000)
      iex> client.timeout
      2000

  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and is_list(opts) do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    %__MODULE__{
      api_key: api_key,
      base_url: validate_option!(:base_url, opts[:base_url]),
      timeout: validate_option!(:timeout, opts[:timeout]),
      req_options: validate_option!(:req_options, opts[:req_options])
    }
  end

  @doc """
  Fetches the forecast for a latitude and longitude in decimal degrees.

  Returns `{:error, %WeatherClient.Error{}}` when the API responds with an
  error status or a body that is not a forecast, or when the request fails.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> build_request(lat, lon)
    |> Req.get()
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast or raises `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp validate_option!(:base_url, base_url) when is_binary(base_url), do: base_url
  defp validate_option!(:timeout, timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp validate_option!(:req_options, req_options) when is_list(req_options), do: req_options

  defp validate_option!(name, value) do
    raise ArgumentError, "invalid value for #{inspect(name)} option: #{inspect(value)}"
  end

  defp build_request(client, lat, lon) do
    request =
      Req.new(
        base_url: client.base_url,
        url: "/forecast",
        params: [lat: lat, lon: lon],
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      )

    Req.merge(request, client.req_options)
  end

  defp handle_response({:ok, %Req.Response{status: status} = response})
       when status in 200..299 do
    parse_forecast(response.body)
  end

  defp handle_response({:ok, %Req.Response{status: status} = response})
       when status in 400..599 do
    {:error, %Error{reason: :api_error, status: status, detail: api_message(response.body)}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, %Error{reason: :unexpected_status, status: status}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :request_failed, detail: exception}}
  end

  defp parse_forecast(%{} = body) do
    with {:ok, temperature_c} <- fetch_field(body, "temperature_c", &is_number/1),
         {:ok, condition} <- fetch_field(body, "condition", &is_binary/1),
         {:ok, wind_kph} <- fetch_field(body, "wind_kph", &is_number/1) do
      {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
    end
  end

  defp parse_forecast(_body), do: invalid_response(:not_a_json_object)

  defp fetch_field(body, key, valid?) do
    case Map.fetch(body, key) do
      {:ok, value} -> validate_field(key, value, valid?)
      :error -> invalid_response({:missing_field, key})
    end
  end

  defp validate_field(key, value, valid?) do
    if valid?.(value), do: {:ok, value}, else: invalid_response({:invalid_field, key})
  end

  defp invalid_response(detail), do: {:error, %Error{reason: :invalid_response, detail: detail}}

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: nil
end

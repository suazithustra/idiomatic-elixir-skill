defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client with `new/1`, then pass it to `forecast/3`:

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.40)
      forecast.temperature_c
      #=> 21.5

  Every function that talks to the API returns `{:ok, value}` or
  `{:error, %WeatherClient.Error{}}`. Functions ending in `!` raise the error
  instead.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(15)

  @enforce_keys [:api_key, :base_url, :timeout]
  @derive {Inspect, except: [:api_key]}
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

    * `:api_key` - the API key sent in the `x-api-key` header. Required.
    * `:base_url` - the API's base URL. Defaults to `#{inspect(@default_base_url)}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `[plug: {Req.Test, WeatherClient}]` in tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", timeout: 5_000)
      iex> client.timeout
      5000

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      ])

    build(opts[:api_key], opts[:base_url], opts[:timeout], opts[:req_options])
  end

  @doc """
  Fetches the forecast for the given latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the request fails, the API answers with an error status, or the
  response body is not a forecast.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    with {:ok, body} <- get(client, "/forecast", lat: lat, lon: lon),
         {:ok, forecast} <- Forecast.from_response(body) do
      {:ok, forecast}
    end
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build(api_key, base_url, timeout, req_options)
       when is_binary(api_key) and api_key != "" and is_binary(base_url) and
              is_integer(timeout) and timeout > 0 and is_list(req_options) do
    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      timeout: timeout,
      req_options: req_options
    }
  end

  defp get(client, path, params) do
    client
    |> req()
    |> Req.get(url: path, params: params)
    |> handle_response()
  end

  defp req(client) do
    Req.new(
      [
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.timeout
      ] ++ client.req_options
    )
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :api_error, status: status, message: api_message(body)}}
  end

  defp handle_response({:error, exception}) when is_exception(exception) do
    {:error, %Error{reason: :transport_error, message: Exception.message(exception)}}
  end

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: nil
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast for one location.

  `:condition` is the condition string the API returns, such as `"cloudy"`.
  It stays a string so that conditions the API adds later still parse.
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
  @spec from_response(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_response(body) when is_map(body) do
    with {:ok, temperature_c} <- number_field(body, "temperature_c"),
         {:ok, condition} <- string_field(body, "condition"),
         {:ok, wind_kph} <- number_field(body, "wind_kph") do
      {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
    end
  end

  def from_response(_body), do: invalid_response(:invalid_body)

  defp number_field(body, key) do
    case Map.fetch(body, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, _value} -> invalid_response({:invalid_field, key})
      :error -> invalid_response({:missing_field, key})
    end
  end

  defp string_field(body, key) do
    case Map.fetch(body, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> invalid_response({:invalid_field, key})
      :error -> invalid_response({:missing_field, key})
    end
  end

  defp invalid_response(reason), do: {:error, %Error{reason: reason}}
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient` functions.

  `:reason` is one of:

    * `:api_error` - the API answered with a non-2xx status. `:status` holds
      the status code and `:message` the API's `"error"` text, if any.
    * `:transport_error` - the request did not complete, for example because
      of a timeout or a refused connection. `:message` describes the cause.
    * `:invalid_body` - a successful response whose body is not a JSON object.
    * `{:missing_field, key}` or `{:invalid_field, key}` - a successful
      response whose body lacks a field or has one of the wrong type.
  """

  defexception [:reason, :status, :message]

  @type reason ::
          :api_error
          | :transport_error
          | :invalid_body
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          message: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, status: status, message: nil}),
    do: "weather API responded with status #{status}"

  def message(%__MODULE__{reason: :api_error, status: status, message: message}),
    do: "weather API responded with status #{status}: #{message}"

  def message(%__MODULE__{reason: :transport_error, message: message}),
    do: "weather API request failed: #{message}"

  def message(%__MODULE__{reason: :invalid_body}),
    do: "weather API response body is not a JSON object"

  def message(%__MODULE__{reason: {:missing_field, key}}),
    do: "weather API response is missing field #{inspect(key)}"

  def message(%__MODULE__{reason: {:invalid_field, key}}),
    do: "weather API response has an invalid #{inspect(key)} field"
end

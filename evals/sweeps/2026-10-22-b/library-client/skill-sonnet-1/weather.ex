defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` functions.

  The `:type` field tells callers what went wrong:

    * `:api` - the API answered with a 4xx/5xx status. `:status` holds the status
      code and `:message` the API's `"error"` text.
    * `:transport` - the request never produced a response (timeout, connection
      refused, ...). `:message` describes the failure.
    * `:invalid_response` - the API answered successfully but the body was not a
      forecast in the expected shape.
  """

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          status: non_neg_integer() | nil,
          message: String.t()
        }

  defexception [:type, :status, :message]
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location.
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
  @spec from_body(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_body(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def from_body(_body) do
    {:error,
     %Error{
       type: :invalid_response,
       message: "response body is not a forecast with temperature_c, condition and wind_kph"
     }}
  end
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

  Build a client once and pass it to every call:

      client = WeatherClient.new("my-api-key", timeout: 5_000)
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.temperature_c
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout]
  defstruct [:api_key, :base_url, :timeout, req_options: []]

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
    * `:timeout` - time in milliseconds to wait for a response. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, for example
      `plug:` in tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("key", base_url: "http://localhost:4000")
      iex> client.base_url
      "http://localhost:4000"
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

  Returns `{:error, %WeatherClient.Error{}}` when the API answers with an error
  status, the request fails, or the response is not a forecast.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> request(url: "/forecast", params: [lat: lat, lon: lon])
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

  defp build(api_key, base_url, timeout, req_options)
       when is_binary(base_url) and is_list(req_options) and
              (timeout == :infinity or (is_integer(timeout) and timeout > 0)) do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout, req_options: req_options}
  end

  defp request(client, request_options) do
    [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]
    |> Keyword.merge(client.req_options)
    |> Req.new()
    |> Req.get(request_options)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    Forecast.from_body(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{type: :api, status: status, message: api_message(body)}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{type: :transport, message: Exception.message(exception)}}
  end

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: "unexpected error response"
end

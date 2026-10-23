defmodule WeatherClient.Error do
  @moduledoc """
  The reason in an `{:error, reason}` returned by `WeatherClient`.

  `:reason` is one of:

    * `:api_error` - the API answered with a 4xx or 5xx status. `:status` holds the
      status and `:message` the `"error"` text from the response body, when there is one.
    * `:invalid_response` - the API answered 200 with a body that is not a forecast.
    * `:transport` - the request did not complete, for example a timeout or a refused
      connection. `:cause` holds the exception Req returned.
  """

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :transport,
          status: non_neg_integer() | nil,
          message: String.t(),
          cause: Exception.t() | nil
        }

  defexception [:reason, :status, :message, :cause]
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by the weather API.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API, built on Req.

  Build a client once with `new/2`, then pass it to `forecast/3`:

      client = WeatherClient.new(System.fetch_env!("WEATHER_API_KEY"))
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.temperature_c

  The client holds no processes and reads no application environment, so several
  clients with different keys or base URLs can be used side by side.
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
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client that authenticates with `api_key`.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options merged into every `Req` request, such as
      `plug:` in tests. Defaults to `[]`.
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
  when the API answers with an error status or the request fails.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    request_options = [
      method: :get,
      url: "/forecast",
      base_url: client.base_url,
      params: [lat: lat, lon: lon],
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]

    request_options
    |> Keyword.merge(client.req_options)
    |> Req.request()
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
       when is_binary(base_url) and is_integer(timeout) and timeout > 0 and
              is_list(req_options) do
    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      timeout: timeout,
      req_options: req_options
    }
  end

  defp handle_response(
         {:ok,
          %Req.Response{
            status: 200,
            body: %{
              "temperature_c" => temperature_c,
              "condition" => condition,
              "wind_kph" => wind_kph
            }
          }}
       )
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  defp handle_response({:ok, %Req.Response{status: 200}}) do
    {:error,
     %Error{reason: :invalid_response, message: "the API returned an unexpected forecast body"}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: %{"error" => message}}})
       when is_binary(message) do
    {:error, %Error{reason: :api_error, status: status, message: message}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error,
     %Error{reason: :api_error, status: status, message: "the API answered with status #{status}"}}
  end

  defp handle_response({:error, exception}) when is_exception(exception) do
    {:error, %Error{reason: :transport, message: Exception.message(exception), cause: exception}}
  end
end

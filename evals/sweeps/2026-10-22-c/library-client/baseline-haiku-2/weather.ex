defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast API.

  Configuration lives under the `:weather_client` application environment:

      config :weather_client,
        api_key: "your-api-key",
        base_url: "https://weather.example.com",
        receive_timeout: 15_000

  Every function also accepts `:api_key`, `:base_url` and `:receive_timeout`
  as options, which take precedence over the application environment. Extra
  options for `Req` can be passed under `:req_options`.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://weather.example.com"
  @default_receive_timeout 15_000

  @type coordinate :: number()

  @doc """
  Fetches the current forecast for the given coordinates.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` when the API returns an error status,
  the request fails at the transport level, or the response is malformed.
  """
  @spec forecast(coordinate(), coordinate(), keyword()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) do
    with {:ok, api_key} <- fetch_api_key(opts) do
      request = build_request(api_key, opts)

      case Req.get(request, params: [lat: lat, lon: lon]) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          decode_forecast(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, Error.from_response(status, body)}

        {:error, exception} ->
          {:error, Error.from_exception(exception)}
      end
    end
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly or raises
  `WeatherClient.Error`.
  """
  @spec forecast!(coordinate(), coordinate(), keyword()) :: Forecast.t()
  def forecast!(lat, lon, opts \\ []) do
    case forecast(lat, lon, opts) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp fetch_api_key(opts) do
    case get_option(opts, :api_key, nil) do
      nil -> {:error, %Error{kind: :missing_api_key, message: "no :api_key configured"}}
      "" -> {:error, %Error{kind: :missing_api_key, message: "no :api_key configured"}}
      api_key -> {:ok, api_key}
    end
  end

  defp build_request(api_key, opts) do
    base_url = get_option(opts, :base_url, @default_base_url)
    receive_timeout = get_option(opts, :receive_timeout, @default_receive_timeout)
    extra = Keyword.get(opts, :req_options, [])

    defaults = [
      url: String.trim_trailing(base_url, "/") <> "/forecast",
      headers: [{"x-api-key", api_key}],
      receive_timeout: receive_timeout
    ]

    Req.new(Keyword.merge(defaults, extra))
  end

  defp get_option(opts, key, default) do
    Keyword.get_lazy(opts, key, fn ->
      Application.get_env(:weather_client, key, default)
    end)
  end

  defp decode_forecast(%{
         "temperature_c" => temperature_c,
         "condition" => condition,
         "wind_kph" => wind_kph
       })
       when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok,
     %Forecast{
       temperature_c: temperature_c,
       condition: condition,
       wind_kph: wind_kph
     }}
  end

  defp decode_forecast(body) do
    {:error,
     %Error{
       kind: :invalid_response,
       message: "unexpected forecast response body",
       body: body
     }}
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc "Current weather conditions for a location."

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  defstruct [:temperature_c, :condition, :wind_kph]
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient`.

  `:kind` is one of:

    * `:http` - the API returned a 4xx or 5xx status; `:status` and `:body` are set
    * `:transport` - the request failed before a response was received; `:reason` holds the exception
    * `:invalid_response` - the API returned a body that does not match the expected shape
    * `:missing_api_key` - no API key was configured
  """

  @type kind :: :http | :transport | :invalid_response | :missing_api_key

  @type t :: %__MODULE__{
          kind: kind(),
          status: non_neg_integer() | nil,
          message: String.t(),
          body: term(),
          reason: Exception.t() | nil
        }

  defexception [:kind, :status, :message, :body, :reason]

  @doc false
  def from_response(status, body) do
    message =
      case body do
        %{"error" => error} when is_binary(error) -> error
        _ -> "HTTP #{status}"
      end

    %__MODULE__{kind: :http, status: status, message: message, body: body}
  end

  @doc false
  def from_exception(exception) do
    %__MODULE__{
      kind: :transport,
      message: Exception.message(exception),
      reason: exception
    }
  end
end

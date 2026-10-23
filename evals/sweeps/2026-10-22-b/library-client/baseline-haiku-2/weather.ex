defmodule WeatherClient do
  @moduledoc """
  Client for the weather API's `/forecast` endpoint.

  Defaults can be set in application config:

      config :weather_client,
        api_key: System.get_env("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 5_000

  Every option can also be passed per call to `forecast/3`.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://weather.example.com"
  @default_timeout 5_000

  @doc """
  Fetches the forecast for the given coordinates.

  ## Options

    * `:api_key` - sent as the `x-api-key` header. Required.
    * `:base_url` - API base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `#{@default_timeout}`.

  ## Examples

      {:ok, %WeatherClient.Forecast{temperature_c: 21.5}} =
        WeatherClient.forecast(59.33, 18.07, api_key: "secret")

  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ []) do
    req = build_request(opts)

    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        Forecast.from_map(body)

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, Error.unexpected(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.http(status, body)}

      {:error, exception} ->
        {:error, Error.transport(exception)}
    end
  end

  defp build_request(opts) do
    api_key = setting(opts, :api_key, nil) || raise ArgumentError, "missing :api_key"

    Req.new(
      base_url: setting(opts, :base_url, @default_base_url),
      receive_timeout: setting(opts, :timeout, @default_timeout),
      headers: [{"x-api-key", api_key}]
    )
  end

  defp setting(opts, key, default) do
    Keyword.get_lazy(opts, key, fn -> Application.get_env(:weather_client, key, default) end)
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast returned by `WeatherClient.forecast/3`.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, WeatherClient.Error.t()}
  def from_map(%{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph})
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok,
     %__MODULE__{
       temperature_c: temperature_c,
       condition: condition,
       wind_kph: wind_kph
     }}
  end

  def from_map(body), do: {:error, WeatherClient.Error.unexpected(body)}
end

defmodule WeatherClient.Error do
  @moduledoc """
  An error returned by `WeatherClient`.

  `:reason` is one of:

    * `:http` - the API responded with a non-200 status. `:status` is set.
    * `:unexpected` - the API responded with 200 but an unrecognized body.
    * `:transport` - the request failed before a response was received.
  """

  defexception [:message, :status, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          status: pos_integer() | nil,
          reason: :http | :unexpected | :transport
        }

  @doc false
  @spec http(pos_integer(), term()) :: t()
  def http(status, body) do
    %__MODULE__{
      message: api_message(body) || "HTTP #{status}",
      status: status,
      reason: :http
    }
  end

  @doc false
  @spec unexpected(term()) :: t()
  def unexpected(body) do
    %__MODULE__{
      message: "unexpected response body: #{inspect(body)}",
      reason: :unexpected
    }
  end

  @doc false
  @spec transport(Exception.t()) :: t()
  def transport(exception) do
    %__MODULE__{
      message: Exception.message(exception),
      reason: :transport
    }
  end

  defp api_message(%{"error" => message}) when is_binary(message), do: message
  defp api_message(_body), do: nil
end

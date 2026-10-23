defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Settings can be set once in application config and overridden per call:

      config :weather_client,
        api_key: System.fetch_env!("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 5_000

  Every request sends the key in the `x-api-key` header.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://weather.example.com"
  @default_timeout 5_000

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` on failure.

  ## Options

    * `:api_key` - API key. Defaults to the `:api_key` config value.
    * `:base_url` - API base URL. Defaults to the `:base_url` config value.
    * `:timeout` - Timeout in milliseconds for connecting and receiving.
      Defaults to the `:timeout` config value.
    * `:req_options` - Extra options passed to `Req.get/2`. These are merged
      last, so they can override the options above.

  ## Examples

      WeatherClient.forecast(52.52, 13.41, api_key: "key")
      #=> {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}
  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) do
    with {:ok, api_key} <- fetch_api_key(opts),
         {:ok, response} <- get("/forecast", [lat: lat, lon: lon], api_key, opts) do
      handle_response(response)
    end
  end

  defp get(path, params, api_key, opts) do
    timeout = Keyword.get(opts, :timeout, config(:timeout, @default_timeout))
    extra = Keyword.get(opts, :req_options, [])

    req_opts =
      [
        base_url: Keyword.get(opts, :base_url, config(:base_url, @default_base_url)),
        params: params,
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout,
        connect_options: [timeout: timeout]
      ]
      |> Keyword.merge(extra)

    case Req.get(path, req_opts) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, exception} ->
        {:error, %Error{kind: :transport, message: Exception.message(exception)}}
    end
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    with {:ok, data} <- decode(body) do
      Forecast.from_map(data)
    end
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    {:error, %Error{kind: :http, status: status, message: error_message(body)}}
  end

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      _ ->
        {:error, %Error{kind: :invalid_response, message: "response body is not a JSON object"}}
    end
  end

  defp decode(_body) do
    {:error, %Error{kind: :invalid_response, message: "response body is not a JSON object"}}
  end

  defp error_message(body) do
    case decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ -> nil
    end
  end

  defp fetch_api_key(opts) do
    case Keyword.get(opts, :api_key, config(:api_key, nil)) do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:error, %Error{kind: :missing_api_key, message: "no API key configured"}}
    end
  end

  defp config(key, default), do: Application.get_env(:weather_client, key, default)
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast returned by `WeatherClient.forecast/3`."

  alias WeatherClient.Error

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(%{"temperature_c" => temperature, "condition" => condition, "wind_kph" => wind})
      when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  def from_map(_data) do
    {:error,
     %Error{kind: :invalid_response, message: "forecast is missing temperature_c, condition or wind_kph"}}
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` functions.

  `kind` is one of:

    * `:missing_api_key` - no API key was given or configured
    * `:http` - the API returned a non-2xx status. `status` and `message` are set
      when the API sent an `{"error": "..."}` body.
    * `:transport` - the request failed before a response arrived (for example a timeout)
    * `:invalid_response` - the API returned a body that is not a valid forecast
  """

  @type kind :: :missing_api_key | :http | :transport | :invalid_response

  @type t :: %__MODULE__{
          kind: kind(),
          status: non_neg_integer() | nil,
          message: String.t() | nil
        }

  defexception [:kind, :status, :message]

  @impl true
  def message(%__MODULE__{kind: kind, status: status, message: message}) do
    details = message || "no details"

    case status do
      nil -> "#{kind}: #{details}"
      status -> "#{kind} (HTTP #{status}): #{details}"
    end
  end
end

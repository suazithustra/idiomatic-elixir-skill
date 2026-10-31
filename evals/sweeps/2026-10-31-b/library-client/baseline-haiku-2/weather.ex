defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API, built on Req.

      {:ok, forecast} = WeatherClient.forecast(51.5, -0.12, api_key: "key")
      forecast.temperature_c
      #=> 21.5

  ## Configuration

  Options passed to `forecast/3` override application config:

    * `:api_key` - sent in the `x-api-key` header. Required.
    * `:base_url` - API root. Defaults to `"https://weather.example.com"`.
    * `:timeout` - receive timeout in milliseconds. Defaults to `15_000`.
    * `:req_options` - extra options merged into `Req.new/1`, for example
      `retry: :transient` or a `plug:` for tests.

  Application config:

      config :weather_client,
        api_key: System.get_env("WEATHER_API_KEY"),
        base_url: "https://weather.example.com",
        timeout: 10_000

  Requests are not retried by default, so a timeout fails after one attempt.
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://weather.example.com"
  @default_timeout 15_000

  @doc """
  Fetches the current forecast for the given coordinates.

  Latitude must be between -90 and 90, longitude between -180 and 180.

  Returns `{:ok, %WeatherClient.Forecast{}}` on success, or
  `{:error, %WeatherClient.Error{}}` on failure.
  """
  @spec forecast(number(), number(), keyword()) ::
          {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(lat, lon, opts \\ []) do
    with :ok <- validate_coordinates(lat, lon),
         {:ok, req} <- build_request(opts) do
      case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          parse_forecast(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, api_error(status, body)}

        {:error, exception} ->
          {:error, %Error{reason: :transport, message: Exception.message(exception)}}
      end
    end
  end

  defp validate_coordinates(lat, lon)
       when is_number(lat) and is_number(lon) and
              lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180,
       do: :ok

  defp validate_coordinates(_lat, _lon) do
    {:error,
     %Error{
       reason: :invalid_coordinates,
       message: "latitude must be between -90 and 90, longitude between -180 and 180"
     }}
  end

  defp build_request(opts) do
    api_key = fetch_option(opts, :api_key, nil)

    if api_key in [nil, ""] do
      {:error, %Error{reason: :missing_api_key, message: "no :api_key configured"}}
    else
      base_url = fetch_option(opts, :base_url, @default_base_url)
      timeout = fetch_option(opts, :timeout, @default_timeout)
      req_options = Keyword.get(opts, :req_options, [])

      req =
        Req.new(
          [
            base_url: base_url,
            receive_timeout: timeout,
            headers: [{"x-api-key", api_key}],
            retry: false
          ]
          |> Keyword.merge(req_options)
        )

      {:ok, req}
    end
  end

  defp fetch_option(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Application.get_env(:weather_client, key, default)
    end
  end

  defp parse_forecast(body) do
    with {:ok, map} <- decode_body(body),
         {:ok, forecast} <- to_forecast(map) do
      {:ok, forecast}
    else
      _ ->
        {:error, %Error{reason: :invalid_response, message: "unexpected response body"}}
    end
  end

  defp to_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp to_forecast(_other), do: :error

  defp api_error(status, body) do
    message =
      case decode_body(body) do
        {:ok, %{"error" => message}} when is_binary(message) -> message
        _ -> "HTTP #{status}"
      end

    %Error{reason: :api, status: status, message: message}
  end

  # Req decodes JSON responses itself. The binary clause covers responses
  # where the content type was not JSON.
  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body), do: {:ok, body}
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  Current weather conditions for one location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient.forecast/3`.

  `:reason` is one of:

    * `:api` - the server returned a non-2xx status. `:status` holds it.
    * `:transport` - the request failed before a response arrived, such as
      a timeout or connection error.
    * `:invalid_response` - a 2xx response did not have the expected fields.
    * `:invalid_coordinates` - latitude or longitude was out of range.
    * `:missing_api_key` - no API key was given in options or config.
  """

  @type reason ::
          :api
          | :transport
          | :invalid_response
          | :invalid_coordinates
          | :missing_api_key

  defexception [:reason, :status, :message]

  @type t :: %__MODULE__{
          reason: reason(),
          status: non_neg_integer() | nil,
          message: String.t() | nil
        }
end

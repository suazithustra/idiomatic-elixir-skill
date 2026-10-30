defmodule WeatherClient do
  @moduledoc """
  Client for the weather forecast HTTP API.

  Settings can be given per call or in the application environment:

      config :weather_client,
        api_key: "your-api-key",
        base_url: "https://api.example.com",
        receive_timeout: 5_000

  Options passed to `forecast/3` take precedence over the application
  environment, which takes precedence over the built-in defaults.
  """

  @default_base_url "https://api.example.com"
  @default_receive_timeout 5_000

  @typedoc "A forecast returned by the API."
  @type forecast :: %{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @typedoc "Errors returned by `forecast/3`."
  @type error ::
          :missing_api_key
          | {:api_error, pos_integer(), String.t() | nil}
          | {:transport_error, Exception.t()}
          | {:unexpected_response, non_neg_integer(), term()}

  @doc """
  Fetches the forecast for a latitude and longitude.

  ## Options

    * `:api_key` - sent in the `x-api-key` header. Required, unless set in
      the application environment.
    * `:base_url` - API base URL. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - timeout in milliseconds. Defaults to
      `#{@default_receive_timeout}`.

  ## Examples

      WeatherClient.forecast(51.5, -0.12, api_key: "key")
      #=> {:ok, %{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}

      WeatherClient.forecast(51.5, -0.12, api_key: "bad-key")
      #=> {:error, {:api_error, 401, "invalid api key"}}
  """
  @spec forecast(number(), number(), keyword()) :: {:ok, forecast()} | {:error, error()}
  def forecast(lat, lon, opts \\ []) when is_number(lat) and is_number(lon) and is_list(opts) do
    with {:ok, config} <- config(opts),
         {:ok, response} <- get_forecast(config, lat, lon) do
      handle_response(response)
    end
  end

  defp config(opts) do
    app = Application.get_all_env(:weather_client)

    api_key = opts[:api_key] || app[:api_key]

    if is_binary(api_key) and api_key != "" do
      {:ok,
       %{
         api_key: api_key,
         base_url: opts[:base_url] || app[:base_url] || @default_base_url,
         receive_timeout:
           opts[:receive_timeout] || app[:receive_timeout] || @default_receive_timeout
       }}
    else
      {:error, :missing_api_key}
    end
  end

  defp get_forecast(config, lat, lon) do
    url = String.trim_trailing(config.base_url, "/") <> "/forecast"

    case Req.get(url,
           headers: [{"x-api-key", config.api_key}],
           params: [lat: lat, lon: lon],
           receive_timeout: config.receive_timeout
         ) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, {:transport_error, exception}}
    end
  end

  defp handle_response(%Req.Response{status: 200, body: body}) do
    with {:ok, decoded} <- decode(body), do: parse_forecast(decoded)
  end

  defp handle_response(%Req.Response{status: status, body: body}) when status >= 400 do
    {:error, {:api_error, status, error_message(body)}}
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    {:error, {:unexpected_response, status, body}}
  end

  defp parse_forecast(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
       when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(other) do
    {:error, {:unexpected_response, 200, other}}
  end

  # Req decodes JSON bodies when the content type says so. Decode by hand
  # when it does not, so a missing content type still works.
  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, {:unexpected_response, 200, body}}
    end
  end

  defp decode(body), do: {:error, {:unexpected_response, 200, body}}

  defp error_message(body) do
    case decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ -> nil
    end
  end
end

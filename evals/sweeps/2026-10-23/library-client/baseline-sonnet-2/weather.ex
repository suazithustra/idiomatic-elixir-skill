defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

  ## Usage

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)

  Options for `new/1`:

    * `:api_key` - required, sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example.com")}`.
    * `:timeout` - receive timeout in milliseconds, defaults to `10_000`.
    * `:req_options` - extra options merged into the underlying `Req` request
      (for example `plug: ...` in tests, or `retry: false`).

  Defaults can also be set in application config:

      config :weather_client, base_url: "https://...", timeout: 5_000
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout 10_000

  @type t :: %__MODULE__{req: Req.Request.t()}

  @enforce_keys [:req]
  defstruct [:req]

  @doc """
  Builds a client. Raises `ArgumentError` if `:api_key` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    api_key =
      Keyword.get(opts, :api_key) ||
        raise ArgumentError, "WeatherClient requires the :api_key option"

    base_url = Keyword.get(opts, :base_url, config(:base_url, @default_base_url))
    timeout = Keyword.get(opts, :timeout, config(:timeout, @default_timeout))
    extra = Keyword.get(opts, :req_options, [])

    req =
      Req.new(
        base_url: base_url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: timeout
      )
      |> Req.merge(extra)

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the forecast for a latitude and longitude.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon) when is_number(lat) and is_number(lon) do
    req
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    case Forecast.from_map(body) do
      {:ok, forecast} -> {:ok, forecast}
      :error -> {:error, %Error{reason: :invalid_response, status: status, message: "unexpected body"}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :api_error, status: status, message: error_message(body)}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :transport, message: Exception.message(exception), exception: exception}}
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil

  defp config(key, default), do: Application.get_env(:weather_client, key, default)
end

defmodule WeatherClient.Forecast do
  @moduledoc "A parsed forecast response."

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @doc false
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{
        "temperature_c" => temp,
        "condition" => condition,
        "wind_kph" => wind
      })
      when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def from_map(_other), do: :error
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` functions.

  `:reason` is `:api_error` (4xx/5xx, with `:status` and the API's `:message`),
  `:transport` (network failure or timeout, with the original `:exception`),
  or `:invalid_response` (2xx with an unexpected body).
  """

  @type t :: %__MODULE__{
          reason: :api_error | :transport | :invalid_response,
          status: non_neg_integer() | nil,
          message: String.t() | nil,
          exception: Exception.t() | nil
        }

  defexception [:reason, :status, :message, :exception]

  @impl true
  def message(%__MODULE__{reason: reason, status: status, message: message}) do
    [to_string(reason), status && "(#{status})", message]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end
end

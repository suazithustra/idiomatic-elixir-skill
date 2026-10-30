defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.temperature_c
      #=> 21.5

  ## Options for `new/1`

    * `:api_key` - required. Sent in the `x-api-key` header on every request.
    * `:base_url` - API base URL. Defaults to `#{inspect("https://api.weather.example")}`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `5_000`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `[plug: {Req.Test, WeatherClient}]` in tests or `[retry: false]`.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 5_000

  @derive {Inspect, except: [:req]}
  defstruct [:req]

  @opaque t :: %__MODULE__{req: Req.Request.t()}

  @type new_option ::
          {:api_key, String.t()}
          | {:base_url, String.t()}
          | {:timeout, non_neg_integer()}
          | {:req_options, keyword()}

  @doc """
  Builds a client. Raises `ArgumentError` if `:api_key` is missing or an option is unknown.
  """
  @spec new([new_option()]) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      ])

    api_key =
      case Keyword.get(opts, :api_key) do
        key when is_binary(key) and key != "" -> key
        _ -> raise ArgumentError, ":api_key is required and must be a non-empty string"
      end

    req =
      Req.new(
        base_url: opts[:base_url],
        headers: [{"x-api-key", api_key}],
        receive_timeout: opts[:timeout]
      )
      |> Req.merge(opts[:req_options])

    %__MODULE__{req: req}
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{req: req}, lat, lon)
      when is_number(lat) and lat >= -90 and lat <= 90 and
             is_number(lon) and lon >= -180 and lon <= 180 do
    case Req.get(req, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, Forecast.from_map(body)}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, %Error{reason: :invalid_response, status: 200, message: inspect(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %Error{reason: :api_error, status: status, message: error_message(body)}}

      {:error, exception} ->
        {:error, %Error{reason: :transport, message: Exception.message(exception)}}
    end
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil
end

defmodule WeatherClient.Forecast do
  @moduledoc "A forecast returned by `WeatherClient.forecast/3`."

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      temperature_c: map["temperature_c"],
      condition: map["condition"],
      wind_kph: map["wind_kph"]
    }
  end
end

defmodule WeatherClient.Error do
  @moduledoc """
  Returned in `{:error, error}` tuples.

  `:reason` is `:api_error` (the API replied with a non-200 status, see `:status`
  and `:message`), `:transport` (connection failure or timeout), or
  `:invalid_response` (200 with an unexpected body).
  """

  defexception [:reason, :status, :message]

  @type t :: %__MODULE__{
          reason: :api_error | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, status: status, message: message}) do
    "weather API returned #{status}" <> if(message, do: ": #{message}", else: "")
  end

  def message(%__MODULE__{reason: reason, message: message}) do
    "weather client #{reason}" <> if(message, do: ": #{message}", else: "")
  end
end

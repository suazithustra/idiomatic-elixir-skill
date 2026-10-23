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

  @doc false
  @spec from_body(map()) :: {:ok, t()} | :error
  def from_body(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind}) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def from_body(_other), do: :error
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned when a request fails.

  `:reason` is one of:

    * `:api` - the API answered with a 4xx/5xx status. `:status` and `:message`
      are set.
    * `:unexpected_body` - the API answered 2xx with a body we could not parse.
      `:body` holds the decoded body.
    * `:transport` - the request never got a response (timeout, connection
      refused, ...). `:message` holds the underlying exception message.
  """

  defexception [:reason, :status, :message, :body]

  @type t :: %__MODULE__{
          reason: :api | :unexpected_body | :transport,
          status: pos_integer() | nil,
          message: String.t() | nil,
          body: term()
        }
end

defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)

  ## Options

  Options are passed to `new/1`:

    * `:api_key` - required. Sent in the `x-api-key` header.
    * `:base_url` - defaults to `#{inspect("https://api.weather.example")}`.
      Can also be set with `config :weather_client, :base_url, "..."`.
    * `:timeout` - milliseconds to wait for a response. Defaults to `5_000`.
    * `:max_retries` - retries for transient failures (timeouts, 408, 429,
      5xx). Defaults to `2`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      e.g. `plug:` to stub responses in tests.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example"
  @default_timeout 5_000
  @default_max_retries 2

  @type t :: Req.Request.t()

  @doc """
  Builds a client. Raises `KeyError` if `:api_key` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    base_url =
      Keyword.get_lazy(opts, :base_url, fn ->
        Application.get_env(:weather_client, :base_url, @default_base_url)
      end)

    [
      base_url: base_url,
      headers: [{"x-api-key", api_key}],
      receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries)
    ]
    |> Req.new()
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%Req.Request{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    case Forecast.from_body(body) do
      {:ok, forecast} -> {:ok, forecast}
      :error -> {:error, %Error{reason: :unexpected_body, status: status, body: body}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{reason: :api, status: status, message: error_message(body), body: body}}
  end

  defp handle_response({:error, exception}) do
    {:error, %Error{reason: :transport, message: Exception.message(exception)}}
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil
end

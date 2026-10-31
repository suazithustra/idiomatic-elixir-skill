defmodule WeatherClient.Forecast do
  @moduledoc """
  A weather forecast as returned by the API.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{"temperature_c" => temp, "condition" => condition, "wind_kph" => wind})
      when is_number(temp) and is_binary(condition) and is_number(wind) do
    {:ok, %__MODULE__{temperature_c: temp, condition: condition, wind_kph: wind}}
  end

  def from_map(_other), do: :error
end

defmodule WeatherClient.Error do
  @moduledoc """
  Error returned by `WeatherClient` functions.

  `:reason` is one of:

    * `:api` - the API answered with a 4xx/5xx status. `:status` and `:message` are set.
    * `:invalid_response` - the API answered 2xx but the body was not a valid forecast.
      `:body` holds the raw body.
    * `:transport` - the request did not complete (timeout, connection refused, ...).
      `:exception` holds the underlying exception.
  """

  defexception [:reason, :status, :message, :body, :exception]

  @type t :: %__MODULE__{
          reason: :api | :invalid_response | :transport,
          status: pos_integer() | nil,
          message: String.t(),
          body: term(),
          exception: Exception.t() | nil
        }
end

defmodule WeatherClient do
  @moduledoc """
  Client for the public weather HTTP API, built on `Req`.

  ## Usage

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
      #=> 21.5

  ## Configuration

  Options can be passed to `new/1`. `:api_key` may also be set in the application
  environment:

      config :weather_client, api_key: "secret"

  Options passed to `new/1` take precedence over application config.
  """

  alias WeatherClient.{Error, Forecast}

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(10)

  @type t :: Req.Request.t()

  @type option ::
          {:api_key, String.t()}
          | {:base_url, String.t()}
          | {:receive_timeout, timeout()}
          | {:req_options, keyword()}

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - API key sent in the `x-api-key` header. Required, either here
      or in the `:weather_client` application environment.
    * `:base_url` - defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for a response. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options merged into `Req.new/1`, for example
      `[plug: {Req.Test, WeatherClient}]` in tests or `[max_retries: 5]`.

  Raises `ArgumentError` if no API key is available.
  """
  @spec new([option()]) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, [:api_key, :base_url, :receive_timeout, :req_options])

    api_key =
      Keyword.get(opts, :api_key) || Application.get_env(:weather_client, :api_key) ||
        raise ArgumentError,
              "missing :api_key; pass it to WeatherClient.new/1 or set " <>
                "config :weather_client, api_key: ..."

    base_url =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:weather_client, :base_url, @default_base_url)

    timeout =
      Keyword.get(opts, :receive_timeout) ||
        Application.get_env(:weather_client, :receive_timeout, @default_timeout)

    [
      base_url: base_url,
      receive_timeout: timeout,
      headers: [{"x-api-key", api_key}]
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}` or `{:error, %WeatherClient.Error{}}`.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%Req.Request{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> Req.get(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `forecast/3` but returns the forecast directly and raises
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    case Forecast.from_map(body) do
      {:ok, forecast} ->
        {:ok, forecast}

      :error ->
        {:error,
         %Error{
           reason: :invalid_response,
           status: status,
           body: body,
           message: "unexpected forecast response body"
         }}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error,
     %Error{
       reason: :api,
       status: status,
       body: body,
       message: error_message(body, status)
     }}
  end

  defp handle_response({:error, exception}) do
    {:error,
     %Error{
       reason: :transport,
       exception: exception,
       message: Exception.message(exception)
     }}
  end

  defp error_message(%{"error" => message}, _status) when is_binary(message), do: message
  defp error_message(_body, status), do: "request failed with status #{status}"
end

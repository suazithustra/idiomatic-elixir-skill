defmodule WeatherClient.Error do
  @moduledoc """
  The error returned (or raised by the bang functions) when a request fails.

  The `:type` field says what went wrong:

    * `:api` - the API answered with a 4xx/5xx status. `:status` holds the
      status code and `:message` the `"error"` text from the response body,
      when there is one.
    * `:transport` - the request never got a response (timeout, connection
      refused, ...). `:reason` holds the underlying exception.
    * `:invalid_response` - the API answered 2xx but the body is not a
      forecast. `:reason` holds the offending body.
  """

  @type t :: %__MODULE__{
          type: :api | :transport | :invalid_response,
          status: pos_integer() | nil,
          message: String.t() | nil,
          reason: term()
        }

  defexception [:type, :status, :message, :reason]

  @impl true
  def message(%__MODULE__{type: :api, status: status, message: message}) do
    "weather API returned status #{status}" <> if(message, do: ": #{message}", else: "")
  end

  def message(%__MODULE__{type: :transport, reason: reason}) do
    "weather API request failed: #{Exception.message(reason)}"
  end

  def message(%__MODULE__{type: :invalid_response}) do
    "weather API returned an unexpected response body"
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast for one location.
  """

  @enforce_keys [:temperature_c, :condition, :wind_kph]
  defstruct [:temperature_c, :condition, :wind_kph]

  @type t :: %__MODULE__{
          temperature_c: number(),
          condition: String.t(),
          wind_kph: number()
        }

  @doc false
  @spec from_body(term()) :: {:ok, t()} | :error
  def from_body(%{
        "temperature_c" => temperature_c,
        "condition" => condition,
        "wind_kph" => wind_kph
      })
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) do
    {:ok, %__MODULE__{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}
  end

  def from_body(_body), do: :error
end

defmodule WeatherClient do
  @moduledoc """
  A client for the weather HTTP API.

  Build a client once with `new/1`, then pass it to `forecast/3`. Nothing is
  read from the application environment, so several clients with different
  keys, base URLs or timeouts can live side by side.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.405)
      forecast.condition
      #=> "cloudy"
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
          timeout: timeout(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - the API key sent in the `x-api-key` header. Required.
    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds.
      Defaults to `#{@default_timeout}`.
    * `:req_options` - extra options merged into the underlying `Req` request,
      for example `[retry: false]` or `[plug: {Req.Test, WeatherClient}]` in
      tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", timeout: 2_000)
      iex> client.timeout
      2000
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      ])

    build(
      Keyword.get(opts, :api_key),
      Keyword.fetch!(opts, :base_url),
      Keyword.fetch!(opts, :timeout),
      Keyword.fetch!(opts, :req_options)
    )
  end

  defp build(api_key, base_url, timeout, req_options)
       when is_binary(api_key) and api_key != "" and is_binary(base_url) and
              (timeout == :infinity or (is_integer(timeout) and timeout > 0)) and
              is_list(req_options) do
    %__MODULE__{api_key: api_key, base_url: base_url, timeout: timeout, req_options: req_options}
  end

  @doc """
  Fetches the current forecast for a latitude and longitude.

  Returns `{:ok, %WeatherClient.Forecast{}}`, or `{:error, %WeatherClient.Error{}}`
  when the API answers with an error status, the request fails, or the body is
  not a forecast.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    client
    |> request(url: "/forecast", params: [lat: lat, lon: lon])
    |> handle_response()
  end

  @doc """
  Same as `forecast/3`, but returns the forecast directly and raises a
  `WeatherClient.Error` on failure.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp request(client, request_opts) do
    base_opts = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]

    base_opts
    |> Keyword.merge(client.req_options)
    |> Req.new()
    |> Req.get(request_opts)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    case Forecast.from_body(body) do
      {:ok, forecast} -> {:ok, forecast}
      :error -> {:error, %Error{type: :invalid_response, reason: body}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, %Error{type: :api, status: status, message: error_message(body)}}
  end

  defp handle_response({:error, exception}) when is_exception(exception) do
    {:error, %Error{type: :transport, reason: exception}}
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil
end

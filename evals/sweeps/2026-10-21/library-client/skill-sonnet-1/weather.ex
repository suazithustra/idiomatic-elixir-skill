defmodule WeatherClient.Error do
  @moduledoc """
  The reason returned in `{:error, reason}` when a request fails.

  The `:type` field says what went wrong:

    * `:api` - the API answered with a 4xx or 5xx status. `:status` holds the
      status code and `:message` the API's `"error"` text.
    * `:invalid_response` - the API answered 2xx but the body was not a
      forecast. `:body` holds the decoded body.
    * `:transport` - the request never got a response (timeout, connection
      refused, ...). `:reason` holds the underlying exception.
  """

  @type t :: %__MODULE__{
          type: :api | :invalid_response | :transport,
          message: String.t(),
          status: pos_integer() | nil,
          body: term(),
          reason: Exception.t() | nil
        }

  defexception [:type, :message, :status, :body, :reason]
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
end

defmodule WeatherClient do
  @moduledoc """
  Client for the weather HTTP API.

      client = WeatherClient.new(api_key: "secret")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
      #=> 21.5
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_receive_timeout :timer.seconds(10)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :receive_timeout]
  defstruct [:api_key, :base_url, :receive_timeout, req_options: []]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: timeout(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - required. Sent in the `x-api-key` header of every request.
    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:receive_timeout` - milliseconds to wait for the response. Defaults to
      `#{@default_receive_timeout}`.
    * `:req_options` - extra options passed to `Req.new/1`, such as `:retry`
      or `:plug` for tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new(api_key: "secret", receive_timeout: 2_000)
      iex> client.receive_timeout
      2000
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :api_key,
        base_url: @default_base_url,
        receive_timeout: @default_receive_timeout,
        req_options: []
      ])

    %__MODULE__{
      api_key: Keyword.fetch!(opts, :api_key),
      base_url: opts[:base_url],
      receive_timeout: opts[:receive_timeout],
      req_options: opts[:req_options]
    }
  end

  @doc """
  Fetches the forecast for a latitude and longitude, in degrees.

  Returns `{:error, %WeatherClient.Error{}}` when the request fails.

  ## Examples

      client = WeatherClient.new(api_key: "secret")
      WeatherClient.forecast(client, 52.52, 13.41)
      #=> {:ok, %WeatherClient.Forecast{temperature_c: 21.5, condition: "cloudy", wind_kph: 12}}
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    with {:ok, response} <- get(client, "/forecast", lat: lat, lon: lon) do
      parse_response(response)
    end
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

  defp get(client, path, params) do
    request =
      Req.new(
        base_url: client.base_url,
        headers: [{"x-api-key", client.api_key}],
        receive_timeout: client.receive_timeout
      )

    request = Req.merge(request, client.req_options)

    case Req.get(request, url: path, params: params) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, transport_error(exception)}
    end
  end

  defp transport_error(exception) do
    %Error{
      type: :transport,
      message: "request failed: " <> Exception.message(exception),
      reason: exception
    }
  end

  defp parse_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    case body do
      %{"temperature_c" => temperature_c, "condition" => condition, "wind_kph" => wind_kph}
      when is_number(temperature_c) and is_binary(condition) and is_number(wind_kph) ->
        {:ok, %Forecast{temperature_c: temperature_c, condition: condition, wind_kph: wind_kph}}

      body ->
        {:error,
         %Error{
           type: :invalid_response,
           message: "unexpected forecast body",
           status: status,
           body: body
         }}
    end
  end

  defp parse_response(%Req.Response{status: status, body: body}) do
    {:error, %Error{type: :api, message: api_message(body, status), status: status, body: body}}
  end

  defp api_message(%{"error" => message}, _status) when is_binary(message), do: message
  defp api_message(_body, status), do: "API returned status #{status}"
end

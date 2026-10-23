defmodule WeatherClient.Error do
  @moduledoc """
  The reason in `{:error, reason}` returned by `WeatherClient`.

  The `:reason` field is one of:

    * `:api_error` - the API answered with a 4xx or 5xx status. `:status` holds
      the status code and `:detail` the `"error"` message from the body, when
      there is one.
    * `:invalid_response` - the API answered with a success status but the body
      is not a forecast. `:detail` holds the body.
    * `:transport` - the request did not complete (connection refused, timeout,
      and so on). `:detail` holds the exception from Req.
  """

  defexception [:reason, :status, :detail]

  @type t :: %__MODULE__{
          reason: :api_error | :invalid_response | :transport,
          status: non_neg_integer() | nil,
          detail: term()
        }

  @impl true
  def message(%__MODULE__{reason: :api_error, status: status, detail: nil}) do
    "weather API returned status #{status}"
  end

  def message(%__MODULE__{reason: :api_error, status: status, detail: detail}) do
    "weather API returned status #{status}: #{detail}"
  end

  def message(%__MODULE__{reason: :invalid_response, detail: detail}) do
    "weather API returned an unexpected body: #{inspect(detail)}"
  end

  def message(%__MODULE__{reason: :transport, detail: exception}) do
    "weather API request failed: #{Exception.message(exception)}"
  end
end

defmodule WeatherClient.Forecast do
  @moduledoc """
  A forecast as returned by the weather API.
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
  A client for the public weather HTTP API.

      client = WeatherClient.new("my-api-key")
      {:ok, forecast} = WeatherClient.forecast(client, 52.52, 13.41)
      forecast.temperature_c
  """

  alias WeatherClient.Error
  alias WeatherClient.Forecast

  @default_base_url "https://api.weather.example.com"
  @default_timeout :timer.seconds(15)

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key, :base_url, :timeout, :req_options]
  defstruct [:api_key, :base_url, :timeout, :req_options]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Builds a client that sends `api_key` in the `x-api-key` header of every request.

  ## Options

    * `:base_url` - the API's base URL. Defaults to `#{@default_base_url}`.
    * `:timeout` - how long to wait for a response, in milliseconds. Defaults to
      `#{@default_timeout}`.
    * `:req_options` - extra options merged into every `Req` request, such as
      `plug:` for tests. Defaults to `[]`.

  ## Examples

      iex> client = WeatherClient.new("secret", timeout: 5_000)
      iex> client.timeout
      5000
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) and byte_size(api_key) > 0 do
    opts =
      Keyword.validate!(opts,
        base_url: @default_base_url,
        timeout: @default_timeout,
        req_options: []
      )

    build(api_key, opts[:base_url], opts[:timeout], opts[:req_options])
  end

  @doc """
  Fetches the forecast for a latitude and longitude.

  Returns `{:error, %WeatherClient.Error{}}` when the API answers with an error
  status, the body is not a forecast, or the request does not complete.
  """
  @spec forecast(t(), number(), number()) :: {:ok, Forecast.t()} | {:error, Error.t()}
  def forecast(%__MODULE__{} = client, lat, lon) when is_number(lat) and is_number(lon) do
    request = build_request(client)

    case Req.get(request, url: "/forecast", params: [lat: lat, lon: lon]) do
      {:ok, %Req.Response{} = response} -> handle_response(response)
      {:error, exception} -> {:error, %Error{reason: :transport, detail: exception}}
    end
  end

  @doc """
  Like `forecast/3`, but returns the forecast or raises the `WeatherClient.Error`.
  """
  @spec forecast!(t(), number(), number()) :: Forecast.t()
  def forecast!(%__MODULE__{} = client, lat, lon) do
    case forecast(client, lat, lon) do
      {:ok, forecast} -> forecast
      {:error, error} -> raise error
    end
  end

  defp build(api_key, base_url, timeout, req_options)
       when is_binary(base_url) and is_integer(timeout) and timeout > 0 and
              is_list(req_options) do
    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      timeout: timeout,
      req_options: req_options
    }
  end

  defp build_request(client) do
    options = [
      base_url: client.base_url,
      headers: [{"x-api-key", client.api_key}],
      receive_timeout: client.timeout
    ]

    options
    |> Keyword.merge(client.req_options)
    |> Req.new()
  end

  defp handle_response(%Req.Response{status: status} = response) when status in 200..299 do
    parse_forecast(response.body)
  end

  defp handle_response(%Req.Response{body: %{"error" => message}} = response)
       when is_binary(message) do
    {:error, %Error{reason: :api_error, status: response.status, detail: message}}
  end

  defp handle_response(%Req.Response{} = response) do
    {:error, %Error{reason: :api_error, status: response.status}}
  end

  defp parse_forecast(%{
         "temperature_c" => temperature,
         "condition" => condition,
         "wind_kph" => wind
       })
       when is_number(temperature) and is_binary(condition) and is_number(wind) do
    {:ok, %Forecast{temperature_c: temperature, condition: condition, wind_kph: wind}}
  end

  defp parse_forecast(body) do
    {:error, %Error{reason: :invalid_response, detail: body}}
  end
end

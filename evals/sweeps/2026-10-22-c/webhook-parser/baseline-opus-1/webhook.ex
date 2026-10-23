defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data carried by a `payment.succeeded` event."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data carried by a `payment.failed` event."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data carried by a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `data` holds a type-specific struct, so callers can pattern match on it:

      case event do
        %Event{data: %PaymentSucceeded{payment_id: id}} -> ...
        %Event{data: %RefundCreated{}} -> ...
      end
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads (string-keyed maps) from the payment provider
  into `Payments.Webhook.Event` structs.

  Input is untrusted, so nothing is converted to atoms dynamically: event types
  are matched against a fixed set and currencies stay strings (upcased to ISO
  4217 form, e.g. `"EUR"`).
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type error ::
          :invalid_payload
          | {:unsupported_event_type, String.t()}
          | {:invalid_field, String.t()}
          | {:missing_field, String.t()}

  @event_types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @doc "Event types this module knows how to parse."
  @spec supported_types() :: [String.t()]
  def supported_types, do: Map.keys(@event_types)

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:unsupported_event_type, type}}` for well-formed events of
  a type we don't handle, so callers can acknowledge and ignore them.

  ## Examples

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_1",
      ...>     "type" => "refund.created",
      ...>     "created" => 1727000000,
      ...>     "data" => %{"refund_id" => "re_1", "payment_id" => "pay_1", "amount" => 500, "currency" => "eur"}
      ...>   })
      iex> event.data
      %Payments.Webhook.RefundCreated{refund_id: "re_1", payment_id: "pay_1", amount: 500, currency: "EUR"}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"type" => type_string, "data" => data} = payload) when is_map(data) do
    with {:ok, type} <- event_type(type_string),
         {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- fetch_timestamp(payload, "created"),
         {:ok, parsed_data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: parsed_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  @doc "Like `parse/1` but raises `ArgumentError` on failure."
  @spec parse!(map()) :: Event.t()
  def parse!(payload) do
    case parse(payload) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid webhook payload: #{inspect(reason)}"
    end
  end

  defp event_type(type) when is_map_key(@event_types, type), do: {:ok, @event_types[type]}
  defp event_type(type) when is_binary(type), do: {:error, {:unsupported_event_type, type}}
  defp event_type(_type), do: {:error, {:invalid_field, "type"}}

  defp parse_data(:payment_succeeded, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, email} <- get_string(data, "customer_email") do
      {:ok,
       %PaymentSucceeded{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end

  defp parse_data(:payment_failed, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, email} <- get_string(data, "customer_email"),
         {:ok, reason} <- get_string(data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency") do
      {:ok,
       %RefundCreated{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end

  # Field helpers. `fetch_*` require the key; `get_*` allow it to be absent or nil.

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_string(map, key) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      error -> error
    end
  end

  defp get_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_amount(map, key) do
    case fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      error -> error
    end
  end

  defp fetch_currency(map, key) do
    with {:ok, code} <- fetch_string(map, key) do
      if code =~ ~r/\A[a-zA-Z]{3}\z/,
        do: {:ok, String.upcase(code)},
        else: {:error, {:invalid_field, key}}
    end
  end

  defp fetch_timestamp(map, key) do
    with {:ok, value} when is_integer(value) <- fetch(map, key),
         {:ok, datetime} <- DateTime.from_unix(value) do
      {:ok, datetime}
    else
      {:error, {:missing_field, _key}} = error -> error
      _other -> {:error, {:invalid_field, key}}
    end
  end
end

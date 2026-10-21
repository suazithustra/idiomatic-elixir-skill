defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` is one of the event-specific structs.
  """

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          occurred_at: DateTime.t(),
          data:
            Payments.Webhook.PaymentSucceeded.t()
            | Payments.Webhook.PaymentFailed.t()
            | Payments.Webhook.RefundCreated.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into structs the
  rest of the app can use.

  The payload is a map with string keys, as produced by a JSON decoder.
  Amounts are integers in minor units (for example, cents for EUR).

  Supported event types:

    * `payment.succeeded` -> `Payments.Webhook.PaymentSucceeded`
    * `payment.failed` -> `Payments.Webhook.PaymentFailed`
    * `refund.created` -> `Payments.Webhook.RefundCreated`

  Any other event type returns `{:error, {:unsupported_type, type}}`, so the
  caller can acknowledge and ignore it.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Fields
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @type error ::
          {:missing, String.t()}
          | {:invalid, String.t()}
          | {:unsupported_type, term()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` or `{:error, reason}`.
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- Fields.string(payload, "id"),
         {:ok, type} <- Fields.string(payload, "type"),
         {:ok, occurred_at} <- Fields.time(payload, "created"),
         {:ok, data} <- Fields.map(payload, "data"),
         {:ok, body} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, {:invalid, "payload"}}

  defp parse_data("payment.succeeded", data), do: PaymentSucceeded.from_map(data)
  defp parse_data("payment.failed", data), do: PaymentFailed.from_map(data)
  defp parse_data("refund.created", data), do: RefundCreated.from_map(data)
  defp parse_data(type, _data), do: {:error, {:unsupported_type, type}}
end

defmodule Payments.Webhook.Fields do
  @moduledoc false

  # Field readers shared by the webhook parser. Each returns `{:ok, value}` or
  # `{:error, {:missing, key}}` / `{:error, {:invalid, key}}`.

  @spec string(map(), String.t()) :: {:ok, String.t()} | {:error, tuple()}
  def string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _} -> {:error, {:invalid, key}}
      :error -> {:error, {:missing, key}}
    end
  end

  @spec optional_string(map(), String.t()) :: {:ok, String.t() | nil} | {:error, tuple()}
  def optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid, key}}
    end
  end

  @spec integer(map(), String.t()) :: {:ok, integer()} | {:error, tuple()}
  def integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _} -> {:error, {:invalid, key}}
      :error -> {:error, {:missing, key}}
    end
  end

  # Amounts are integer minor units and cannot be negative.
  @spec amount(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, tuple()}
  def amount(map, key) do
    case integer(map, key) do
      {:ok, value} when value >= 0 -> {:ok, value}
      {:ok, _} -> {:error, {:invalid, key}}
      error -> error
    end
  end

  # Returns the currency as an upper-case ISO 4217 code, e.g. "eur" -> "EUR".
  @spec currency(map(), String.t()) :: {:ok, String.t()} | {:error, tuple()}
  def currency(map, key) do
    case string(map, key) do
      {:ok, code} ->
        if String.match?(code, ~r/\A[A-Za-z]{3}\z/),
          do: {:ok, String.upcase(code)},
          else: {:error, {:invalid, key}}

      error ->
        error
    end
  end

  # Unix seconds to a UTC DateTime.
  @spec time(map(), String.t()) :: {:ok, DateTime.t()} | {:error, tuple()}
  def time(map, key) do
    with {:ok, seconds} <- integer(map, key) do
      case DateTime.from_unix(seconds) do
        {:ok, datetime} -> {:ok, datetime}
        {:error, _} -> {:error, {:invalid, key}}
      end
    end
  end

  @spec map(map(), String.t()) :: {:ok, map()} | {:error, tuple()}
  def map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:error, {:invalid, key}}
      :error -> {:error, {:missing, key}}
    end
  end
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data carried by a `payment.succeeded` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, tuple()}
  def from_map(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data, "currency"),
         {:ok, email} <- Fields.optional_string(data, "customer_email") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data carried by a `payment.failed` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, tuple()}
  def from_map(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data, "currency"),
         {:ok, email} <- Fields.optional_string(data, "customer_email"),
         {:ok, reason} <- Fields.optional_string(data, "failure_reason") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data carried by a `refund.created` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}

  @spec from_map(map()) :: {:ok, t()} | {:error, tuple()}
  def from_map(data) do
    with {:ok, refund_id} <- Fields.string(data, "refund_id"),
         {:ok, payment_id} <- Fields.string(data, "payment_id") do
      {:ok, %__MODULE__{refund_id: refund_id, payment_id: payment_id}}
    end
  end
end

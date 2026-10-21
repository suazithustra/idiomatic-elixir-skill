defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data of a `payment.succeeded` event."

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
  @moduledoc "Data of a `payment.failed` event."

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
  @moduledoc "Data of a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct @enforce_keys

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

  `id` is the provider's event id; use it to drop duplicate deliveries.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct @enforce_keys

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
  Turns decoded webhook payloads from the payment provider into
  `Payments.Webhook.Event` structs.

  Amounts stay in integer minor units. Currencies are upcased to ISO 4217
  codes (`"eur"` becomes `"EUR"`). The `created` Unix timestamp becomes a
  UTC `DateTime`.

  Event types we don't handle return
  `{:error, {:unsupported_event_type, type}}`, so the caller can
  acknowledge them to the provider and move on.
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event_type, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Errors name the offending field but never include its value, so they are
  safe to log.

  ## Examples

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_123",
      ...>     "type" => "payment.succeeded",
      ...>     "created" => 1727000000,
      ...>     "data" => %{
      ...>       "payment_id" => "pay_9",
      ...>       "amount" => 1250,
      ...>       "currency" => "eur",
      ...>       "customer_email" => "a@example.com",
      ...>       "failure_reason" => nil
      ...>     }
      ...>   })
      iex> event.data
      %Payments.Webhook.PaymentSucceeded{
        payment_id: "pay_9",
        amount: 1250,
        currency: "EUR",
        customer_email: "a@example.com"
      }

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created"})
      {:error, {:unsupported_event_type, "customer.created"}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, type} <- required(payload, "type", &string/1),
         {:ok, type} <- event_type(type),
         {:ok, id} <- required(payload, "id", &string/1),
         {:ok, created_at} <- required(payload, "created", &unix_time/1),
         {:ok, data} <- required(payload, "data", &map/1),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(type), do: {:error, {:unsupported_event_type, type}}

  defp parse_data(:payment_succeeded, data) do
    with {:ok, payment_id} <- required(data, "payment_id", &string/1),
         {:ok, amount} <- required(data, "amount", &amount/1),
         {:ok, currency} <- required(data, "currency", &currency/1),
         {:ok, email} <- optional(data, "customer_email", &string/1) do
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
    with {:ok, payment_id} <- required(data, "payment_id", &string/1),
         {:ok, amount} <- required(data, "amount", &amount/1),
         {:ok, currency} <- required(data, "currency", &currency/1),
         {:ok, email} <- optional(data, "customer_email", &string/1),
         {:ok, reason} <- optional(data, "failure_reason", &string/1) do
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
    with {:ok, refund_id} <- required(data, "refund_id", &string/1),
         {:ok, payment_id} <- required(data, "payment_id", &string/1),
         {:ok, amount} <- required(data, "amount", &amount/1),
         {:ok, currency} <- required(data, "currency", &currency/1) do
      {:ok,
       %RefundCreated{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end

  # Field access. `nil` counts as absent, matching how the provider
  # sends empty fields.

  defp required(map, key, cast) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> cast(value, key, cast)
    end
  end

  defp optional(map, key, cast) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> cast(value, key, cast)
    end
  end

  defp cast(value, key, cast) do
    case cast.(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  # Casts. Each returns `{:ok, value}` or `:error`.

  defp string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp string(_value), do: :error

  defp amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp amount(_value), do: :error

  defp currency(value) when is_binary(value) do
    if value =~ ~r/\A[a-z]{3}\z/i, do: {:ok, String.upcase(value)}, else: :error
  end

  defp currency(_value), do: :error

  defp unix_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp unix_time(_value), do: :error

  defp map(value) when is_map(value), do: {:ok, value}
  defp map(_value), do: :error
end

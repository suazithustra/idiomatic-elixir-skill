defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  Data for a `payment.succeeded` event. `amount` is in minor units of `currency`.
  """

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
  @moduledoc """
  Data for a `payment.failed` event. `amount` is in minor units of `currency`.
  """

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
  @moduledoc """
  Data for a `refund.created` event. `amount` is in minor units of `currency`.
  """

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
  A parsed webhook event. `id` is the provider's event id; use it to drop
  duplicate deliveries. `data` holds the event-specific struct.
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
  Turns decoded webhook payloads (maps with string keys) from the payment
  provider into `Payments.Webhook.Event` structs.

  Supported event types and the struct placed in `event.data`:

    * `"payment.succeeded"` - `Payments.Webhook.PaymentSucceeded`
    * `"payment.failed"` - `Payments.Webhook.PaymentFailed`
    * `"refund.created"` - `Payments.Webhook.RefundCreated`

  Any other type returns `{:error, {:unsupported_event_type, type}}`, so the
  caller can acknowledge and ignore it.

  Currency codes are normalised to upper case (`"eur"` becomes `"EUR"`).
  Error reasons name the offending field but never include its value, so they
  are safe to log without leaking customer data.

  This module does not check the webhook signature. Do that on the raw request
  body before decoding the JSON.
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type error_reason ::
          :not_a_map
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event_type, String.t()}

  @doc """
  Parses a decoded webhook payload.

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9", "amount" => 500, "currency" => "eur"}
      ...> })
      {:ok,
       %Payments.Webhook.Event{
         id: "evt_1",
         type: :refund_created,
         created_at: ~U[2024-09-22 10:13:20Z],
         data: %Payments.Webhook.RefundCreated{refund_id: "re_1", payment_id: "pay_9", amount: 500, currency: "EUR"}
       }}

  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error_reason()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- required(payload, "id", &non_empty_string/1),
         {:ok, type_name} <- required(payload, "type", &non_empty_string/1),
         {:ok, type} <- event_type(type_name),
         {:ok, created_at} <- required(payload, "created", &unix_time/1),
         {:ok, data} <- required(payload, "data", &map/1),
         {:ok, data} <- type |> parse_data(data) |> in_data() do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  def parse(_payload), do: {:error, :not_a_map}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(other), do: {:error, {:unsupported_event_type, other}}

  defp parse_data(:payment_succeeded, data) do
    with {:ok, payment_id} <- required(data, "payment_id", &non_empty_string/1),
         {:ok, amount} <- required(data, "amount", &amount/1),
         {:ok, currency} <- required(data, "currency", &currency/1),
         {:ok, email} <- optional(data, "customer_email", &non_empty_string/1) do
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
    with {:ok, payment_id} <- required(data, "payment_id", &non_empty_string/1),
         {:ok, amount} <- required(data, "amount", &amount/1),
         {:ok, currency} <- required(data, "currency", &currency/1),
         {:ok, email} <- optional(data, "customer_email", &non_empty_string/1),
         {:ok, reason} <- optional(data, "failure_reason", &non_empty_string/1) do
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
    with {:ok, refund_id} <- required(data, "refund_id", &non_empty_string/1),
         {:ok, payment_id} <- required(data, "payment_id", &non_empty_string/1),
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

  # Prefixes field names in errors from `parse_data/2` so they read "data.amount".
  defp in_data({:error, {:missing_field, key}}), do: {:error, {:missing_field, "data." <> key}}
  defp in_data({:error, {:invalid_field, key}}), do: {:error, {:invalid_field, "data." <> key}}
  defp in_data({:ok, _data} = ok), do: ok

  # A key that is absent or `nil` counts as missing.
  defp required(map, key, validate) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> validate(value, key, validate)
    end
  end

  defp optional(map, key, validate) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> validate(value, key, validate)
    end
  end

  defp validate(value, key, validate) do
    case validate.(value) do
      {:ok, _value} = ok -> ok
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp non_empty_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty_string(_value), do: :error

  defp unix_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp unix_time(_value), do: :error

  defp map(value) when is_map(value), do: {:ok, value}
  defp map(_value), do: :error

  defp amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp amount(_value), do: :error

  defp currency(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z]{3}\z/, do: {:ok, String.upcase(value)}, else: :error
  end

  defp currency(_value), do: :error
end

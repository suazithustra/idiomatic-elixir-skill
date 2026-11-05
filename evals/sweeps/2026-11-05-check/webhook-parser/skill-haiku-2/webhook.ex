defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` is a `Payments.Webhook.Payment` for payment
  events and a `Payments.Webhook.Refund` for `:refund_created`.
  """

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  Data from a `payment.succeeded` or `payment.failed` event.

  `amount` is in integer minor units (cents). `currency` is an upper-case
  ISO 4217 code. `failure_reason` is `nil` unless the provider sent one.
  """

  @enforce_keys [:payment_id, :status, :amount, :currency, :customer_email]
  defstruct [:payment_id, :status, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          status: :succeeded | :failed,
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  Data from a `refund.created` event.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into structs.

  Handles `payment.succeeded`, `payment.failed` and `refund.created`. Any other
  event type returns an error, so the caller decides whether to acknowledge it.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @doc """
  Parses a payload whose keys are strings, as decoded from JSON.

  Returns `{:ok, %Payments.Webhook.Event{}}` or `{:error, reason}`. Reasons:

    * `:invalid_payload` - the payload lacks `id`, `type`, `created` or `data`,
      or is not a map
    * `{:unsupported_event, type}` - an event type this module does not handle
    * `{:missing_field, key}` - a field the event type requires is absent
    * `{:invalid_field, key}` - a field is present with a value of the wrong shape

  ## Examples

      iex> Payments.Webhook.parse(%{})
      {:error, :invalid_payload}

      iex> payload = %{"id" => "evt_1", "type" => "customer.created", "created" => 1, "data" => %{}}
      iex> Payments.Webhook.parse(payload)
      {:error, {:unsupported_event, "customer.created"}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data}) do
    with {:ok, id} <- check(id, "id", &non_empty_string?/1),
         {:ok, kind} <- event_kind(type),
         {:ok, created_at} <- created_at(created),
         {:ok, body} <- parse_data(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(other), do: {:error, {:unsupported_event, other}}

  defp created_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp created_at(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(:payment_succeeded, data) when is_map(data), do: parse_payment(data, :succeeded)
  defp parse_data(:payment_failed, data) when is_map(data), do: parse_payment(data, :failed)
  defp parse_data(:refund_created, data) when is_map(data), do: parse_refund(data)
  defp parse_data(_kind, _data), do: {:error, {:invalid_field, "data"}}

  defp parse_payment(data, status) do
    with {:ok, payment_id} <- field(data, "payment_id", &non_empty_string?/1),
         {:ok, amount} <- field(data, "amount", &minor_units?/1),
         {:ok, currency} <- field(data, "currency", &currency_code?/1),
         {:ok, customer_email} <- field(data, "customer_email", &non_empty_string?/1),
         {:ok, failure_reason} <- optional_string(data, "failure_reason") do
      payment = %Payment{
        payment_id: payment_id,
        status: status,
        amount: amount,
        currency: String.upcase(currency),
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- field(data, "refund_id", &non_empty_string?/1),
         {:ok, payment_id} <- field(data, "payment_id", &non_empty_string?/1) do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  # Required field: a missing key and a wrong value get different reasons.
  defp field(data, key, valid) do
    case Map.fetch(data, key) do
      {:ok, value} -> check(value, key, valid)
      :error -> {:error, {:missing_field, key}}
    end
  end

  # Optional field: absent or nil is fine, anything else must be a string.
  defp optional_string(data, key) do
    case data[key] do
      nil -> {:ok, nil}
      value -> check(value, key, &is_binary/1)
    end
  end

  defp check(value, key, valid) do
    if valid.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp minor_units?(value), do: is_integer(value) and value >= 0

  defp currency_code?(value), do: is_binary(value) and String.match?(value, ~r/\A[A-Za-z]{3}\z/)
end

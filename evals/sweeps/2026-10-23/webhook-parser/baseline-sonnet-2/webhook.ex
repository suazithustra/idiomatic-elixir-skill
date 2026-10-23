defmodule Payments.Webhook.Money do
  @moduledoc "An amount in integer minor units (for example cents) and an upper-case ISO 4217 currency code."

  @enforce_keys [:amount, :currency]
  defstruct [:amount, :currency]

  @type t :: %__MODULE__{amount: integer(), currency: String.t()}
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A payment was collected."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :money]
  defstruct [:event_id, :occurred_at, :payment_id, :money, :customer_email]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          money: Payments.Webhook.Money.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A payment attempt failed. `failure_reason` is the provider's text, if any."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :money]
  defstruct [:event_id, :occurred_at, :payment_id, :money, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          money: Payments.Webhook.Money.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A refund was created against a payment. `money` is nil if the provider omitted the amount."

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
  defstruct [:event_id, :occurred_at, :refund_id, :payment_id, :money]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          money: Payments.Webhook.Money.t() | nil
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload (string-keyed map) into a struct.

  `parse/1` returns `{:ok, event}` or `{:error, reason}`. An event type we do not
  handle returns `{:error, {:unsupported_type, type}}`, so the caller can
  acknowledge it instead of treating it as a malformed request.
  """

  alias Payments.Webhook.{Money, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => %{} = data})
      when is_binary(id) and is_binary(type) do
    with {:ok, occurred_at} <- parse_timestamp(created) do
      build(type, %{event_id: id, occurred_at: occurred_at}, data)
    end
  end

  def parse(%{} = payload) do
    case Enum.find(["id", "type", "created", "data"], &(not Map.has_key?(payload, &1))) do
      nil -> {:error, :invalid_payload}
      key -> {:error, {:missing_field, key}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp build("payment.succeeded", base, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, money} <- fetch_money(data),
         {:ok, email} <- optional_string(data, "customer_email") do
      {:ok,
       struct!(
         PaymentSucceeded,
         Map.merge(base, %{payment_id: payment_id, money: money, customer_email: email})
       )}
    end
  end

  defp build("payment.failed", base, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, money} <- fetch_money(data),
         {:ok, email} <- optional_string(data, "customer_email"),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       struct!(
         PaymentFailed,
         Map.merge(base, %{
           payment_id: payment_id,
           money: money,
           customer_email: email,
           failure_reason: reason
         })
       )}
    end
  end

  defp build("refund.created", base, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, money} <- optional_money(data) do
      {:ok,
       struct!(
         RefundCreated,
         Map.merge(base, %{refund_id: refund_id, payment_id: payment_id, money: money})
       )}
    end
  end

  defp build(type, _base, _data), do: {:error, {:unsupported_type, type}}

  defp parse_timestamp(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_timestamp(_), do: {:error, {:invalid_field, "created"}}

  defp fetch_string(data, key) do
    case data do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(data, key) do
    case data do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:ok, nil}
    end
  end

  defp fetch_money(%{"amount" => amount, "currency" => currency})
       when is_integer(amount) and amount >= 0 and is_binary(currency) and
              byte_size(currency) == 3 do
    {:ok, %Money{amount: amount, currency: String.upcase(currency)}}
  end

  defp fetch_money(data) do
    cond do
      not Map.has_key?(data, "amount") -> {:error, {:missing_field, "amount"}}
      not Map.has_key?(data, "currency") -> {:error, {:missing_field, "currency"}}
      not is_integer(data["amount"]) or data["amount"] < 0 -> {:error, {:invalid_field, "amount"}}
      true -> {:error, {:invalid_field, "currency"}}
    end
  end

  defp optional_money(%{"amount" => nil}), do: {:ok, nil}
  defp optional_money(%{"amount" => _} = data), do: fetch_money(data)
  defp optional_money(_), do: {:ok, nil}
end

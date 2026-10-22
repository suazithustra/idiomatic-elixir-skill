defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.
  """

  @type payment_event :: %{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @type t ::
          {:payment_succeeded, base()}
          | {:payment_failed, base()}
          | {:refund_created, base()}

  @type base :: %{id: String.t(), created_at: DateTime.t()}
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A payment completed successfully."
  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A payment attempt failed."
  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct @enforce_keys ++ [failure_reason: nil]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A refund was created for a payment."
  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id, :amount, :currency]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded payment-provider webhook payloads into structs.

  Amounts are integer minor units; currencies are normalised to upper-case
  ISO 4217 codes.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @doc """
  Parses a decoded payload.

  Returns `{:ok, event}`, or `{:error, reason}`. An unknown event type yields
  `{:error, {:unsupported_type, type}}` so callers can acknowledge and ignore it.
  """
  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => %{} = data})
      when is_binary(id) and is_binary(type) do
    with {:ok, occurred_at} <- parse_timestamp(created) do
      build(type, %{event_id: id, occurred_at: occurred_at}, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp build("payment.succeeded", base, data) do
    with {:ok, fields} <- payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, Map.merge(base, fields))}
    end
  end

  defp build("payment.failed", base, data) do
    with {:ok, fields} <- payment_fields(data),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok, struct!(PaymentFailed, base |> Map.merge(fields) |> Map.put(:failure_reason, reason))}
    end
  end

  defp build("refund.created", base, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data) do
      {:ok,
       struct!(
         RefundCreated,
         Map.merge(base, %{
           refund_id: refund_id,
           payment_id: payment_id,
           amount: amount,
           currency: currency
         })
       )}
    end
  end

  defp build(type, _base, _data), do: {:error, {:unsupported_type, type}}

  defp payment_fields(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data),
         {:ok, email} <- optional_string(data, "customer_email") do
      {:ok, %{payment_id: payment_id, amount: amount, currency: currency, customer_email: email}}
    end
  end

  defp parse_timestamp(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_timestamp(_), do: {:error, {:invalid_field, "created"}}

  defp fetch_string(data, key) do
    case data do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(data, key) do
    case data do
      %{^key => value} when is_binary(value) or is_nil(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:ok, nil}
    end
  end

  defp fetch_amount(data) do
    case data do
      %{"amount" => amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      %{"amount" => _} -> {:error, {:invalid_field, "amount"}}
      _ -> {:error, {:missing_field, "amount"}}
    end
  end

  defp fetch_currency(data) do
    with {:ok, currency} <- fetch_string(data, "currency") do
      {:ok, String.upcase(currency)}
    end
  end
end

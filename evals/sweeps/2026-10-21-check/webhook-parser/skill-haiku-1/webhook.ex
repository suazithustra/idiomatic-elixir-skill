defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is an integer in minor units (for example, cents).
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` event."

  @enforce_keys [:id, :occurred_at, :payment]
  defstruct [:id, :occurred_at, :payment]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          payment: Payments.Webhook.Payment.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A `payment.failed` event. `failure_reason` is `nil` when the provider sends none."

  @enforce_keys [:id, :occurred_at, :payment]
  defstruct [:id, :occurred_at, :payment, failure_reason: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          payment: Payments.Webhook.Payment.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A `refund.created` event."

  @enforce_keys [:id, :occurred_at, :refund_id, :payment_id]
  defstruct [:id, :occurred_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into an event struct.

  Supported types are `payment.succeeded`, `payment.failed`, and `refund.created`.
  Any other type returns `{:error, {:unsupported_event, type}}`.
  """

  alias Payments.Webhook.{Payment, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a webhook payload whose keys are strings.

  ## Examples

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "customer.created"}}

  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, type} <- required_string(payload, "type"),
         {:ok, kind} <- event_kind(type),
         {:ok, envelope} <- envelope(payload) do
      build(kind, envelope)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(other), do: {:error, {:unsupported_event, other}}

  defp envelope(payload) do
    with {:ok, id} <- required_string(payload, "id"),
         {:ok, created} <- required_integer(payload, "created"),
         {:ok, occurred_at} <- from_unix_seconds(created),
         {:ok, data} <- required_map(payload, "data") do
      {:ok, %{id: id, occurred_at: occurred_at, data: data}}
    end
  end

  defp build(:payment_succeeded, envelope) do
    with {:ok, payment} <- payment(envelope.data) do
      {:ok,
       %PaymentSucceeded{id: envelope.id, occurred_at: envelope.occurred_at, payment: payment}}
    end
  end

  defp build(:payment_failed, envelope) do
    with {:ok, payment} <- payment(envelope.data),
         {:ok, failure_reason} <- nullable_string(envelope.data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         id: envelope.id,
         occurred_at: envelope.occurred_at,
         payment: payment,
         failure_reason: failure_reason
       }}
    end
  end

  defp build(:refund_created, envelope) do
    with {:ok, refund_id} <- required_string(envelope.data, "refund_id"),
         {:ok, payment_id} <- required_string(envelope.data, "payment_id") do
      {:ok,
       %RefundCreated{
         id: envelope.id,
         occurred_at: envelope.occurred_at,
         refund_id: refund_id,
         payment_id: payment_id
       }}
    end
  end

  defp payment(data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- required_integer(data, "amount"),
         {:ok, currency} <- required_string(data, "currency"),
         {:ok, customer_email} <- required_string(data, "customer_email") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp from_unix_seconds(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp required_string(data, key) do
    case data do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp required_integer(data, key) do
    case data do
      %{^key => value} when is_integer(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp required_map(data, key) do
    case data do
      %{^key => value} when is_map(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp nullable_string(data, key) do
    case data do
      %{^key => value} when is_binary(value) or is_nil(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:ok, nil}
    end
  end
end

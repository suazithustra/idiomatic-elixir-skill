defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `object` is a `Payments.Webhook.Payment` for `payment.succeeded` and
  `payment.failed`, and a `Payments.Webhook.Refund` for `refund.created`.
  """

  @enforce_keys [:id, :type, :occurred_at, :object]
  defstruct [:id, :type, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          object: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment reported as succeeded or failed. `amount` is in minor units.
  `failure_reason` is set only when `status` is `:failed`.
  """

  @enforce_keys [:id, :status, :amount, :currency, :customer_email]
  defstruct [:id, :status, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :succeeded | :failed,
          amount: integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  A refund of a payment.
  """

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id]

  @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a payment provider's webhook payload into structs the app can use.

  The payload is the JSON already decoded into maps with string keys. The
  handled event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Amounts stay integer minor units (cents).
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a decoded webhook payload into a `Payments.Webhook.Event`.

  Returns `{:error, {:unsupported_event, type}}` for an event type this module
  does not handle, `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` for a bad field in `data`, and
  `{:error, :invalid_payload}` when the top-level keys are absent.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.object
      %Payments.Webhook.Refund{id: "re_1", payment_id: "pay_9"}
  """
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, event_type} <- event_type(type),
         {:ok, occurred_at} <- parse_created(created),
         {:ok, object} <- parse_object(event_type, data) do
      {:ok, %Event{id: id, type: event_type, occurred_at: occurred_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_object(:payment_succeeded, data), do: parse_payment(data, :succeeded)
  defp parse_object(:payment_failed, data), do: parse_payment(data, :failed)
  defp parse_object(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data, status) do
    with {:ok, id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- failure_reason(data, status) do
      payment = %Payment{
        id: id,
        status: status,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp failure_reason(data, :failed), do: string_field(data, "failure_reason")
  defp failure_reason(_data, :succeeded), do: {:ok, nil}

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{id: refund_id, payment_id: payment_id}}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp integer_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end

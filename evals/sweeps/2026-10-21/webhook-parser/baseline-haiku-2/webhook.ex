defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event. `data` is a `Payment` or a `Refund`."

  @type kind :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          occurred_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }

  defstruct [:id, :kind, :occurred_at, :data]
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details from a `payment.succeeded` or `payment.failed` event.

  `failure_reason` is always `nil` for successful payments.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]
end

defmodule Payments.Webhook.Refund do
  @moduledoc "Refund details from a `refund.created` event."

  @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}

  defstruct [:id, :payment_id]
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment provider webhook payloads into typed structs.

  The input is a map with string keys, as produced by a JSON decoder.
  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Any other type returns `{:error, {:unsupported_type, type}}`
  so the caller can decide whether to acknowledge and ignore it.

  Amounts are integers in minor units (for example cents). Currency codes are
  returned upcased (`"eur"` becomes `"EUR"`).
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @kinds %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @doc "Event type strings this module can parse."
  @spec supported_types() :: [String.t()]
  def supported_types, do: Map.keys(@kinds)

  @doc """
  Parses a webhook payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` on success, or an error tuple
  describing the first problem found.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, kind} <- kind(type),
         {:ok, occurred_at} <- to_datetime(created),
         {:ok, body} <- parse_data(kind, data) do
      {:ok, %Event{id: id, kind: kind, occurred_at: occurred_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp kind(type) do
    case Map.fetch(@kinds, type) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:unsupported_type, type}}
    end
  end

  defp to_datetime(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_data(:payment_succeeded, data), do: parse_payment(data, nil)

  defp parse_data(:payment_failed, data) do
    with {:ok, reason} <- optional_string(data, "failure_reason") do
      parse_payment(data, reason)
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- required_string(data, "refund_id"),
         {:ok, payment_id} <- required_string(data, "payment_id") do
      {:ok, %Refund{id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_payment(data, failure_reason) do
    with {:ok, id} <- required_string(data, "payment_id"),
         {:ok, amount} <- minor_units(data, "amount"),
         {:ok, currency} <- currency(data),
         {:ok, email} <- optional_string(data, "customer_email") do
      {:ok,
       %Payment{
         id: id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: failure_reason
       }}
    end
  end

  defp required_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_string(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp minor_units(data, key) do
    case Map.get(data, key) do
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp currency(data) do
    case Map.get(data, "currency") do
      code when is_binary(code) ->
        if String.match?(code, ~r/\A[A-Za-z]{3}\z/),
          do: {:ok, String.upcase(code)},
          else: {:error, {:invalid_field, "currency"}}

      _ ->
        {:error, {:invalid_field, "currency"}}
    end
  end
end

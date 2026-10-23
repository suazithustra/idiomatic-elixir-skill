defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment details carried by a `payment.succeeded` or `payment.failed` event.

  `amount` is in integer minor units (cents). `failure_reason` is `nil` for
  successful payments.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund details carried by a `refund.created` event.

  `amount` and `currency` are `nil` when the provider leaves them out.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A validated webhook event.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          occurred_at: DateTime.t(),
          data: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into a
  `Payments.Webhook.Event`.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          :invalid_payload
          | {:unsupported_event, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a string-keyed payload map.

  Returns `{:error, {:unsupported_event, type}}` for event types we do not
  handle, `{:error, {:missing_field, key}}` when a required field is absent and
  `{:error, {:invalid_field, key}}` when a field has the wrong type or value.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_1"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.data.refund_id}
      {:refund_created, "re_1"}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse("nope")
      {:error, :invalid_payload}
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{} = payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, occurred_at} <- timestamp_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, event_type} <- parse_type(type),
         {:ok, details} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, occurred_at: occurred_at, data: details}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)

  defp parse_data(:payment_failed, data) do
    with {:ok, payment} <- parse_payment(data),
         {:ok, reason} <- optional_field(data, "failure_reason", &string_field/2) do
      {:ok, %Payment{payment | failure_reason: reason}}
    end
  end

  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, email} <- string_field(data, "customer_email") do
      {:ok,
       %Payment{payment_id: payment_id, amount: amount, currency: currency, customer_email: email}}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_field(data, "amount", &amount_field/2),
         {:ok, currency} <- optional_field(data, "currency", &string_field/2) do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, %{} = value} -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp timestamp_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> unix_to_datetime(value, key)
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp unix_to_datetime(seconds, key) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_field(map, key, parse_field) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _value} -> parse_field.(map, key)
      %{} -> {:ok, nil}
    end
  end
end

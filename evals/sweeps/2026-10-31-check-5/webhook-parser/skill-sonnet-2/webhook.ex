defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is in integer minor units (cents for `eur`).
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

defmodule Payments.Webhook.Refund do
  @moduledoc """
  Refund details carried by `refund.created` events.

  `amount` is in integer minor units and is `nil` when the provider omits it.
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

  @enforce_keys [:id, :type, :created, :data]
  defstruct [:id, :type, :created, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created: DateTime.t(),
          data: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload (a map with string keys) into an
  `Payments.Webhook.Event`.

  Handled event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type reason ::
          :invalid_payload
          | {:unsupported_event, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded payload.

  Returns `{:error, :invalid_payload}` when `"id"`, `"type"`, `"created"` or
  `"data"` is absent, `{:error, {:unsupported_event, type}}` for an event type
  the app does not handle, and `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` when a field of a handled event is wrong.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1727000000,
      ...>   "data" => %{
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 1250,
      ...>     "currency" => "eur",
      ...>     "customer_email" => "a@example.com",
      ...>     "failure_reason" => nil
      ...>   }
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.data.amount, event.created}
      {:payment_succeeded, 1250, ~U[2024-09-22 10:13:20Z]}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}

      iex> payload = %{"id" => "evt_1", "type" => "invoice.paid", "created" => 1727000000, "data" => %{}}
      iex> Payments.Webhook.parse(payload)
      {:error, {:unsupported_event, "invoice.paid"}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, reason()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
    with {:ok, id} <- string_field(%{"id" => id}, "id"),
         {:ok, type} <- parse_type(type),
         {:ok, created} <- parse_created(created),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created: created, data: data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} ->
        {:ok, datetime}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(:refund_created, data), do: parse_refund(data)
  defp parse_data(_payment_type, data), do: parse_payment(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_amount_field(data, "amount"),
         {:ok, currency} <- optional_string_field(data, "currency") do
      refund = %Refund{
        refund_id: refund_id,
        payment_id: payment_id,
        amount: amount,
        currency: currency
      }

      {:ok, refund}
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) or is_nil(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} ->
        {:ok, nil}

      :error ->
        {:ok, nil}

      {:ok, _value} ->
        amount_field(map, key)
    end
  end
end

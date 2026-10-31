defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment details carried by a `payment.succeeded` or `payment.failed` event.

  `amount` is in integer minor units (for example cents). `failure_reason` is
  `nil` unless the provider sent one.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  @derive {Inspect, except: [:customer_email]}
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

  `amount` is in integer minor units and is `nil` when the provider did not send it.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `data` is a `Payments.Webhook.Payment` for the payment types and a
  `Payments.Webhook.Refund` for `:refund_created`.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into an
  `Payments.Webhook.Event`.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          :invalid_payload
          | {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a string-keyed payload into an event.

  Returns `{:error, :invalid_payload}` when the envelope (`"id"`, `"type"`,
  `"created"`, `"data"`) is missing or malformed,
  `{:error, {:unsupported_event, type}}` for an event type the app does not
  handle, and `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  when a field of `"data"` is absent or has the wrong shape.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_1"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.data.refund_id, event.created_at}
      {:refund_created, "re_1", ~U[2024-09-22 09:46:40Z]}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, kind} <- parse_type(type),
         {:ok, created_at} <- parse_created(created),
         {:ok, details} <- parse_data(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, data: details}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} ->
        {:ok, created_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(kind, data) when kind in [:payment_succeeded, :payment_failed] do
    parse_payment(data)
  end

  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
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
         {:ok, amount} <- optional_amount_field(data, "amount") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount}}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:ok, nil}
    end
  end

  defp optional_amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, nil} ->
        {:ok, nil}

      :error ->
        {:ok, nil}

      {:ok, _value} ->
        amount_field(data, key)
    end
  end
end

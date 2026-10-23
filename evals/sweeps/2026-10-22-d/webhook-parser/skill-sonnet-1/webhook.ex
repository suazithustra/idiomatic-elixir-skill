defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment outcome reported by the provider.

  `failure_reason` is set only when `status` is `:failed`.
  """

  @enforce_keys [:payment_id, :status, :amount, :currency]
  defstruct [:payment_id, :status, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          status: :succeeded | :failed,
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  A refund created against an earlier payment.
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
  Turns decoded payment provider webhook payloads into `Payments.Webhook.Event` structs.

  Amounts are integer minor units (for example cents).
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          :invalid_payload
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for a malformed payload, and `{:error, {:unsupported_event, type}}` for an
  event type the app does not handle, so callers can acknowledge those.

  ## Examples

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_1"}
      ...> })
      {:ok,
       %Payments.Webhook.Event{
         id: "evt_1",
         type: :refund_created,
         created_at: ~U[2024-09-22 09:46:40Z],
         data: %Payments.Webhook.Refund{refund_id: "re_1", payment_id: "pay_1"}
       }}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, {:missing_field, "type"}}

      iex> Payments.Webhook.parse("nope")
      {:error, :invalid_payload}
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type_name} <- string_field(payload, "type"),
         {:ok, created} <- integer_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, type} <- parse_type(type_name),
         {:ok, created_at} <- parse_created(created),
         {:ok, event_data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_data(:payment_succeeded, data), do: parse_payment(data, :succeeded)

  defp parse_data(:payment_failed, data) do
    with {:ok, payment} <- parse_payment(data, :failed),
         {:ok, reason} <- string_field(data, "failure_reason") do
      {:ok, %Payment{payment | failure_reason: reason}}
    end
  end

  defp parse_data(:refund_created, data) do
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

  defp parse_payment(data, status) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, email} <- optional_string_field(data, "customer_email") do
      payment = %Payment{
        payment_id: payment_id,
        status: status,
        amount: amount,
        currency: currency,
        customer_email: email
      }

      {:ok, payment}
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _value} -> string_field(map, key)
      %{} -> {:ok, nil}
    end
  end

  defp integer_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(map, key) do
    case integer_field(map, key) do
      {:ok, amount} when amount >= 0 -> {:ok, amount}
      {:ok, _negative} -> {:error, {:invalid_field, key}}
      {:error, _reason} = error -> error
    end
  end

  defp optional_amount_field(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _value} -> amount_field(map, key)
      %{} -> {:ok, nil}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads into structs.

  Supported event types: `payment.succeeded`, `payment.failed`, `refund.created`.
  Amounts are integers in minor units (for example cents).
  """

  defmodule PaymentSucceeded do
    @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency]
    defstruct [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]

    @type t :: %__MODULE__{
            event_id: String.t(),
            occurred_at: DateTime.t(),
            payment_id: String.t(),
            amount: non_neg_integer(),
            currency: String.t(),
            customer_email: String.t() | nil
          }
  end

  defmodule PaymentFailed do
    @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency]
    defstruct [
      :event_id,
      :occurred_at,
      :payment_id,
      :amount,
      :currency,
      :customer_email,
      :failure_reason
    ]

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

  defmodule RefundCreated do
    @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
    defstruct [:event_id, :occurred_at, :refund_id, :payment_id, :amount, :currency]

    @type t :: %__MODULE__{
            event_id: String.t(),
            occurred_at: DateTime.t(),
            refund_id: String.t(),
            payment_id: String.t(),
            amount: non_neg_integer() | nil,
            currency: String.t() | nil
          }
  end

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:unsupported_event_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Turns a decoded webhook payload into an event struct.

  Returns `{:error, {:unsupported_event_type, type}}` for event types the app
  does not handle, so callers can acknowledge and ignore them.
  """
  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{"type" => type, "data" => data} = payload) when is_map(data) do
    with {:ok, event_id} <- fetch_string(payload, "id"),
         {:ok, occurred_at} <- fetch_timestamp(payload, "created") do
      build(type, %{event_id: event_id, occurred_at: occurred_at}, data)
    end
  end

  def parse(%{"type" => _}), do: {:error, {:missing_field, "data"}}
  def parse(%{}), do: {:error, {:missing_field, "type"}}
  def parse(_), do: {:error, :invalid_payload}

  defp build("payment.succeeded", base, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, email} <- fetch_optional_string(data, "customer_email") do
      {:ok,
       struct!(
         PaymentSucceeded,
         Map.merge(base, %{
           payment_id: payment_id,
           amount: amount,
           currency: currency,
           customer_email: email
         })
       )}
    end
  end

  defp build("payment.failed", base, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, email} <- fetch_optional_string(data, "customer_email"),
         {:ok, reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok,
       struct!(
         PaymentFailed,
         Map.merge(base, %{
           payment_id: payment_id,
           amount: amount,
           currency: currency,
           customer_email: email,
           failure_reason: reason
         })
       )}
    end
  end

  defp build("refund.created", base, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_optional_amount(data, "amount"),
         {:ok, currency} <- fetch_optional_currency(data, "currency") do
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

  defp build(type, _base, _data), do: {:error, {:unsupported_event_type, type}}

  defp fetch_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> {:error, {:invalid_field, key}}
      %{} -> {:ok, nil}
    end
  end

  defp fetch_amount(map, key) do
    case map do
      %{^key => value} when is_integer(value) and value >= 0 -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_amount(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> fetch_amount(map, key)
      %{} -> {:ok, nil}
    end
  end

  defp fetch_currency(map, key) do
    with {:ok, value} <- fetch_string(map, key) do
      normalize_currency(value, key)
    end
  end

  defp fetch_optional_currency(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> fetch_currency(map, key)
      %{} -> {:ok, nil}
    end
  end

  # ISO 4217 codes are three letters; the provider sends them lowercase.
  defp normalize_currency(code, key) do
    if code =~ ~r/\A[A-Za-z]{3}\z/,
      do: {:ok, String.upcase(code)},
      else: {:error, {:invalid_field, key}}
  end

  defp fetch_timestamp(map, key) do
    case map do
      %{^key => value} when is_integer(value) ->
        case DateTime.from_unix(value) do
          {:ok, datetime} -> {:ok, datetime}
          {:error, _} -> {:error, {:invalid_field, key}}
        end

      %{^key => nil} ->
        {:error, {:missing_field, key}}

      %{^key => _} ->
        {:error, {:invalid_field, key}}

      %{} ->
        {:error, {:missing_field, key}}
    end
  end
end

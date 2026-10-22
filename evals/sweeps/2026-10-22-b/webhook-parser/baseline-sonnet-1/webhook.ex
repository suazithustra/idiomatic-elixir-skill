defmodule Payments.Webhook.Event do
  @moduledoc """
  A validated, normalized webhook event.
  """

  @type kind :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: kind(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          refund_id: String.t() | nil,
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @enforce_keys [:id, :type, :created_at, :payment_id, :amount, :currency]
  defstruct [
    :id,
    :type,
    :created_at,
    :payment_id,
    :refund_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads into
  `Payments.Webhook.Event` structs.

  Amounts are integer minor units. Currencies are normalized to upper-case
  ISO 4217 codes.
  """

  alias Payments.Webhook.Event

  @type error ::
          {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @doc """
  Parses a decoded payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` or `{:error, reason}`.
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
    with {:ok, kind} <- parse_type(type),
         {:ok, id} <- string(id, "id"),
         {:ok, created_at} <- timestamp(created),
         {:ok, fields} <- parse_data(kind, data) do
      {:ok, struct!(Event, [id: id, type: kind, created_at: created_at] ++ fields)}
    end
  end

  def parse(%{} = payload) do
    case Enum.find(~w(id type created data), &(not Map.has_key?(payload, &1))) do
      nil -> {:error, {:invalid_field, "data"}}
      key -> {:error, {:missing_field, key}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type) when is_binary(type), do: {:error, {:unsupported_type, type}}
  defp parse_type(_), do: {:error, {:invalid_field, "type"}}

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data) do
      {:ok,
       [
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: optional_string(data, "customer_email")
       ]}
    end
  end

  defp parse_data(kind, data) when kind in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data) do
      {:ok,
       [
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: optional_string(data, "customer_email"),
         failure_reason: if(kind == :payment_failed, do: optional_string(data, "failure_reason"))
       ]}
    end
  end

  defp fetch_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> string(value, key)
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp string(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp string(_, key), do: {:error, {:invalid_field, key}}

  defp optional_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp fetch_amount(data) do
    case Map.fetch(data, "amount") do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:missing_field, "amount"}}
    end
  end

  defp fetch_currency(data) do
    with {:ok, currency} <- fetch_string(data, "currency") do
      {:ok, String.upcase(currency)}
    end
  end

  defp timestamp(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp timestamp(_), do: {:error, {:invalid_field, "created"}}
end

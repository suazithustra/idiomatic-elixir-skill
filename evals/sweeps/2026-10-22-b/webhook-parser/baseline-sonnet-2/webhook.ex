defmodule Payments.Webhook.Event do
  @moduledoc """
  A normalized payment-provider webhook event.
  """

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
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
  Parses decoded webhook payloads (string-keyed maps) into
  `Payments.Webhook.Event` structs.

  Returns `{:ok, event}` or `{:error, reason}`, where reason is one of:

    * `{:unsupported_type, type}`
    * `{:missing_field, field}`
    * `{:invalid_field, field}`
    * `:invalid_payload`
  """

  alias Payments.Webhook.Event

  @types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @type error ::
          {:unsupported_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => _, "type" => type, "data" => %{}} = payload) do
    case Map.fetch(@types, type) do
      {:ok, atom} -> build(atom, payload)
      :error -> {:error, {:unsupported_type, type}}
    end
  end

  def parse(%{} = payload) do
    case Enum.find(["id", "type", "data"], &(not Map.has_key?(payload, &1))) do
      nil -> {:error, {:invalid_field, "data"}}
      field -> {:error, {:missing_field, field}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp build(type, %{"id" => id, "data" => data} = payload) do
    with {:ok, id} <- string(id, "id"),
         {:ok, created_at} <- timestamp(payload["created"]),
         {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, refund_id} <- refund_id(type, data),
         {:ok, amount} <- amount(data["amount"]),
         {:ok, currency} <- currency(data["currency"]),
         {:ok, email} <- optional_string(data, "customer_email"),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       %Event{
         id: id,
         type: type,
         created_at: created_at,
         payment_id: payment_id,
         refund_id: refund_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp refund_id(:refund_created, data), do: required_string(data, "refund_id")
  defp refund_id(_type, _data), do: {:ok, nil}

  defp timestamp(nil), do: {:error, {:missing_field, "created"}}

  defp timestamp(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp timestamp(_), do: {:error, {:invalid_field, "created"}}

  defp amount(nil), do: {:error, {:missing_field, "amount"}}
  defp amount(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp amount(_), do: {:error, {:invalid_field, "amount"}}

  defp currency(nil), do: {:error, {:missing_field, "currency"}}

  defp currency(c) when is_binary(c) and byte_size(c) == 3, do: {:ok, String.upcase(c)}
  defp currency(_), do: {:error, {:invalid_field, "currency"}}

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> string(value, key)
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> string(value, key)
    end
  end

  defp string(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp string(_value, key), do: {:error, {:invalid_field, key}}
end

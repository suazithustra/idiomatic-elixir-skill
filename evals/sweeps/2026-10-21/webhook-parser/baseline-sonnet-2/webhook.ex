defmodule Payments.Webhook.Payment do
  @moduledoc "Payload of a `payment.succeeded` or `payment.failed` event."

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
  @moduledoc "Payload of a `refund.created` event."

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
  @moduledoc "A parsed webhook event."

  alias Payments.Webhook.{Payment, Refund}

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
  Parses decoded webhook payloads (maps with string keys) from the payment
  provider into `Payments.Webhook.Event` structs.

  Amounts are integers in minor units (for example cents). Currencies are
  normalised to upper-case ISO 4217 codes.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :invalid_payload
          | {:unsupported_event_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
    with {:ok, id} <- string(%{"id" => id}, "id"),
         {:ok, event_type} <- event_type(type),
         {:ok, created_at} <- timestamp(created),
         {:ok, data} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: data}}
    end
  end

  def parse(payload) when is_map(payload) do
    case Enum.find(~w(id type created data), &(not Map.has_key?(payload, &1))) do
      nil -> {:error, {:invalid_field, "data"}}
      key -> {:error, {:missing_field, key}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(type) when is_binary(type), do: {:error, {:unsupported_event_type, type}}
  defp event_type(_), do: {:error, {:invalid_field, "type"}}

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- string(data, "payment_id"),
         {:ok, amount} <- amount(data, "amount"),
         {:ok, currency} <- currency(data, "currency"),
         {:ok, email} <- optional_string(data, "customer_email"),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string(data, "refund_id"),
         {:ok, payment_id} <- string(data, "payment_id"),
         {:ok, amount} <- optional_amount(data, "amount"),
         {:ok, currency} <- optional_currency(data, "currency") do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp timestamp(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp timestamp(_), do: {:error, {:invalid_field, "created"}}

  defp string(map, key) do
    case map do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:ok, nil}
    end
  end

  defp amount(map, key) do
    case map do
      %{^key => value} when is_integer(value) and value >= 0 -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp optional_amount(map, key) do
    if Map.get(map, key) == nil, do: {:ok, nil}, else: amount(map, key)
  end

  defp currency(map, key) do
    with {:ok, code} <- string(map, key) do
      if byte_size(code) == 3 do
        {:ok, String.upcase(code)}
      else
        {:error, {:invalid_field, key}}
      end
    end
  end

  defp optional_currency(map, key) do
    if Map.get(map, key) == nil, do: {:ok, nil}, else: currency(map, key)
  end
end

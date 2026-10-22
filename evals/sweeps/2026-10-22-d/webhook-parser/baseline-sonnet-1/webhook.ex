defmodule Payments.Webhook.Event do
  @moduledoc """
  A normalized webhook event.

  `type` is one of `:payment_succeeded`, `:payment_failed` or `:refund_created`.
  `data` is a struct specific to the event type.
  """

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]
end

defmodule Payments.Webhook.Payment do
  @moduledoc "Payment details carried by payment events. Amount is in minor units."

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]
end

defmodule Payments.Webhook.Refund do
  @moduledoc "Refund details carried by refund events. Amount is in minor units."

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount, :currency]
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads (string-keyed maps) into
  `Payments.Webhook.Event` structs.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :invalid_payload
          | {:unknown_event_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @event_types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, event_type} <- event_type(type),
         {:ok, created_at} <- parse_timestamp(created),
         {:ok, payload} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: payload}}
    end
  end

  def parse(payload) when is_map(payload) do
    case Enum.find(~w(id type created data), &(not Map.has_key?(payload, &1))) do
      nil -> {:error, :invalid_payload}
      key -> {:error, {:missing_field, key}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp event_type(type) do
    case @event_types do
      %{^type => event_type} -> {:ok, event_type}
      _ -> {:error, {:unknown_event_type, type}}
    end
  end

  defp parse_timestamp(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_timestamp(_), do: {:error, {:invalid_field, "created"}}

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_string(data, "currency"),
         {:ok, email} <- optional_string(data, "customer_email"),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: String.upcase(currency),
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- optional_amount(data, "amount"),
         {:ok, currency} <- optional_string(data, "currency") do
      {:ok,
       %Refund{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency && String.upcase(currency)
       }}
    end
  end

  defp fetch_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) or is_nil(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:ok, nil}
    end
  end

  defp fetch_amount(map, key) do
    case map do
      %{^key => value} when is_integer(value) and value >= 0 -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp optional_amount(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> fetch_amount(map, key)
      _ -> {:ok, nil}
    end
  end
end

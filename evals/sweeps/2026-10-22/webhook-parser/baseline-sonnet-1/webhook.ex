defmodule Payments.Webhook.Payment do
  @moduledoc "Payment details carried by `payment.succeeded` and `payment.failed` events."

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
  @moduledoc "Refund details carried by `refund.created` events."

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
  Parses decoded payment-provider webhook payloads (string-keyed maps) into
  `Payments.Webhook.Event` structs.

  Amounts are integers in minor units (for example cents) and are never converted.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @doc """
  Parses a payload.

  Returns `{:ok, %Event{}}`, or `{:error, reason}` when the event type is not
  one we handle or a required field is missing or malformed.

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_1"}
      ...> })
      {:ok,
       %Payments.Webhook.Event{
         id: "evt_1",
         type: :refund_created,
         created_at: ~U[2024-09-22 10:13:20Z],
         data: %Payments.Webhook.Refund{refund_id: "re_1", payment_id: "pay_1"}
       }}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"type" => type_string} = payload) when is_binary(type_string) do
    with {:ok, type} <- event_type(type_string),
         {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- fetch_timestamp(payload, "created"),
         {:ok, data} <- fetch_map(payload, "data"),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  def parse(%{}), do: {:error, {:missing_field, "type"}}
  def parse(_), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(other), do: {:error, {:unsupported_type, other}}

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_string(data, "currency"),
         {:ok, email} <- fetch_optional_string(data, "customer_email"),
         {:ok, reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: String.downcase(currency),
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_optional_amount(data, "amount"),
         {:ok, currency} <- fetch_optional_string(data, "currency") do
      {:ok,
       %Refund{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency && String.downcase(currency)
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

  defp fetch_optional_string(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => value} when is_binary(value) -> {:ok, value}
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

  defp fetch_optional_amount(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> fetch_amount(map, key)
      _ -> {:ok, nil}
    end
  end

  defp fetch_map(map, key) do
    case map do
      %{^key => value} when is_map(value) -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_timestamp(map, key) do
    with %{^key => value} when is_integer(value) <- map,
         {:ok, datetime} <- DateTime.from_unix(value) do
      {:ok, datetime}
    else
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      {:error, _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end
end

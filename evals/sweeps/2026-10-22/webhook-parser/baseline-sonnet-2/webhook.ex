defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads (string-keyed maps) into
  structs the rest of the app can pattern match on.

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 1250,
      ...>     "currency" => "eur",
      ...>     "customer_email" => "a@example.com"
      ...>   }
      ...> })
      {:ok,
       %Payments.Webhook.Event{
         id: "evt_1",
         type: :payment_succeeded,
         created_at: ~U[2024-09-22 09:46:40Z],
         data: %Payments.Webhook.Payment{
           payment_id: "pay_9",
           amount: 1250,
           currency: "EUR",
           customer_email: "a@example.com",
           failure_reason: nil
         }
       }}
  """

  defmodule Payment do
    @moduledoc "Payload of `payment.succeeded` and `payment.failed` events."
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

  defmodule Refund do
    @moduledoc "Payload of `refund.created` events."
    @enforce_keys [:refund_id, :payment_id]
    defstruct [:refund_id, :payment_id, :amount, :currency]

    @type t :: %__MODULE__{
            refund_id: String.t(),
            payment_id: String.t(),
            amount: non_neg_integer() | nil,
            currency: String.t() | nil
          }
  end

  defmodule Event do
    @moduledoc "A parsed webhook event. Amounts are integer minor units."
    @enforce_keys [:id, :type, :created_at, :data]
    defstruct [:id, :type, :created_at, :data]

    @type type :: :payment_succeeded | :payment_failed | :refund_created

    @type t :: %__MODULE__{
            id: String.t(),
            type: type(),
            created_at: DateTime.t(),
            data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
          }
  end

  @type error ::
          {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:unsupported_type, type}}` for event types we do not
  handle, so callers can acknowledge them without treating them as failures.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"type" => type} = payload) when is_binary(type) do
    with {:ok, type_atom} <- fetch_type(type),
         {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- fetch_timestamp(payload, "created"),
         {:ok, raw_data} <- fetch_map(payload, "data"),
         {:ok, data} <- parse_data(type_atom, raw_data) do
      {:ok, %Event{id: id, type: type_atom, created_at: created_at, data: data}}
    end
  end

  def parse(%{} = _payload), do: {:error, {:missing_field, "type"}}
  def parse(_other), do: {:error, :invalid_payload}

  defp fetch_type(type) do
    case @types do
      %{^type => atom} -> {:ok, atom}
      _ -> {:error, {:unsupported_type, type}}
    end
  end

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
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
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- optional(data, "amount", &fetch_amount/2),
         {:ok, currency} <- optional(data, "currency", &fetch_currency/2) do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
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

  defp fetch_map(map, key) do
    case map do
      %{^key => %{} = value} -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
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

  defp fetch_currency(map, key) do
    with {:ok, value} <- fetch_string(map, key) do
      {:ok, String.upcase(value)}
    end
  end

  defp fetch_timestamp(map, key) do
    with {:ok, seconds} <- fetch_amount(map, key),
         {:ok, datetime} <- DateTime.from_unix(seconds) do
      {:ok, datetime}
    else
      {:error, :invalid_unix_time} -> {:error, {:invalid_field, key}}
      {:error, _} = error -> error
    end
  end

  # Fields that may be absent or null; present values must still be valid.
  defp optional(map, key, fetch_fun) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _} -> fetch_fun.(map, key)
      _ -> {:ok, nil}
    end
  end

  defp optional_string(map, key), do: optional(map, key, &fetch_string/2)
end

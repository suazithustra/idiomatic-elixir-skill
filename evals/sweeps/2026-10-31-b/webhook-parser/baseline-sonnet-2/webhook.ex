defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads (string-keyed maps) into
  structs the rest of the app can pattern match on.

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> })
      {:ok,
       %Payments.Webhook.Event{
         id: "evt_1",
         type: :refund_created,
         created_at: ~U[2024-09-22 09:46:40Z],
         data: %Payments.Webhook.Refund{
           refund_id: "re_1",
           payment_id: "pay_9",
           amount: nil,
           currency: nil
         }
       }}

  Amounts are integers in minor units (e.g. cents).
  """

  defmodule Payment do
    @moduledoc "Data for `payment.succeeded` and `payment.failed` events."
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
    @moduledoc "Data for `refund.created` events."
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
    @moduledoc "A parsed webhook event."
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

  @type error ::
          :invalid_payload
          | {:unsupported_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"type" => type} = payload) do
    with {:ok, event_type} <- event_type(type),
         {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- fetch_timestamp(payload, "created"),
         {:ok, data} <- fetch_map(payload, "data"),
         {:ok, parsed} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: parsed}}
    end
  end

  def parse(%{}), do: {:error, {:missing_field, "type"}}
  def parse(_other), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(other), do: {:error, {:unsupported_type, other}}

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)

  defp parse_data(:payment_failed, data) do
    with {:ok, payment} <- parse_payment(data),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok, %{payment | failure_reason: reason}}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- optional_amount(data, "amount"),
         {:ok, currency} <- optional_string(data, "currency") do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp parse_payment(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_string(data, "currency"),
         {:ok, email} <- optional_string(data, "customer_email") do
      {:ok,
       %Payment{payment_id: payment_id, amount: amount, currency: currency, customer_email: email}}
    end
  end

  # Field helpers

  defp fetch_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(map, key) do
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

  defp optional_amount(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{} when not is_map_key(map, key) -> {:ok, nil}
      _ -> fetch_amount(map, key)
    end
  end

  defp fetch_map(map, key) do
    case map do
      %{^key => %{} = value} -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_timestamp(map, key) do
    with {:ok, seconds} <- fetch_integer(map, key),
         {:ok, datetime} <- DateTime.from_unix(seconds) do
      {:ok, datetime}
    else
      {:error, {_, _}} = error -> error
      {:error, _} -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_integer(map, key) do
    case map do
      %{^key => value} when is_integer(value) -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end
end

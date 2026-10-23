defmodule Payments.Webhook.Event do
  @moduledoc """
  A normalized webhook event.

  `:data` is one of the payload structs in `Payments.Webhook.*`.
  """

  @type data ::
          Payments.Webhook.PaymentSucceeded.t()
          | Payments.Webhook.PaymentFailed.t()
          | Payments.Webhook.RefundCreated.t()

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          created_at: DateTime.t(),
          data: data()
        }

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data for a `payment.succeeded` event. `amount` is in minor units."

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data for a `payment.failed` event. `amount` is in minor units."

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

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data for a `refund.created` event. `amount` is in minor units, if present."

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

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_1",
      ...>     "type" => "refund.created",
      ...>     "created" => 1_727_000_000,
      ...>     "data" => %{"refund_id" => "re_1", "payment_id" => "pay_1"}
      ...>   })
      iex> event.type
      :refund_created
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type error ::
          {:unknown_event_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @doc """
  Parses a payload into an event.

  Returns `{:error, {:unknown_event_type, type}}` for event types we don't
  handle so callers can acknowledge and ignore them.
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created} = payload)
      when is_binary(id) and is_binary(type) do
    with {:ok, event_type} <- event_type(type),
         {:ok, created_at} <- parse_created(created),
         {:ok, data} <- fetch_data(payload),
         {:ok, parsed} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: parsed}}
    end
  end

  def parse(%{"id" => _, "type" => _, "created" => _}), do: {:error, :invalid_payload}

  def parse(%{} = payload) do
    case Enum.find(~w(id type created), &(not Map.has_key?(payload, &1))) do
      nil -> {:error, :invalid_payload}
      key -> {:error, {:missing_field, key}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(other), do: {:error, {:unknown_event_type, other}}

  defp parse_created(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_), do: {:error, {:invalid_field, "created"}}

  defp fetch_data(%{"data" => %{} = data}), do: {:ok, data}
  defp fetch_data(%{"data" => _}), do: {:error, {:invalid_field, "data"}}
  defp fetch_data(_), do: {:error, {:missing_field, "data"}}

  defp parse_data(:payment_succeeded, data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- amount(data, "amount"),
         {:ok, currency} <- currency(data),
         {:ok, email} <- optional_string(data, "customer_email") do
      {:ok,
       %PaymentSucceeded{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end

  defp parse_data(:payment_failed, data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- amount(data, "amount"),
         {:ok, currency} <- currency(data),
         {:ok, email} <- optional_string(data, "customer_email"),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- required_string(data, "refund_id"),
         {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- optional_amount(data, "amount"),
         {:ok, currency} <- optional_currency(data) do
      {:ok,
       %RefundCreated{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end

  defp required_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, _} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp amount(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, _} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_amount(data, key) do
    if Map.get(data, key) == nil, do: {:ok, nil}, else: amount(data, key)
  end

  # Currency codes are normalized to upper-case ISO 4217 (e.g. "eur" -> "EUR").
  defp currency(data) do
    with {:ok, code} <- required_string(data, "currency"), do: normalize_currency(code)
  end

  defp optional_currency(data) do
    with {:ok, code} <- optional_string(data, "currency") do
      if code, do: normalize_currency(code), else: {:ok, nil}
    end
  end

  defp normalize_currency(code) when byte_size(code) == 3, do: {:ok, String.upcase(code)}
  defp normalize_currency(_), do: {:error, {:invalid_field, "currency"}}
end

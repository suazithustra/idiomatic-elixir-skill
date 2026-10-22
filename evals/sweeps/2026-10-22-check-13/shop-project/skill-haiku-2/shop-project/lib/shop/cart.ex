defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, :discount_code]

  @type sku :: String.t()
  @type discount_code :: :save10 | :freeship
  @type t :: %__MODULE__{
          items: %{sku() => pos_integer()},
          discount_code: discount_code() | nil
        }

  @doc "Returns an empty cart."
  @spec new() :: t()
  def new, do: %__MODULE__{items: %{}}

  @doc "Adds `quantity` units of `sku` to the cart."
  @spec add_item(t(), sku(), pos_integer()) :: t()
  def add_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: Map.update(cart.items, sku, quantity, &(&1 + quantity))}
  end

  @doc """
  Removes `quantity` units of `sku` from the cart.

  Removing at least as many units as the cart holds removes the item. An SKU
  the cart does not hold leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      {:ok, _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      :error ->
        cart
    end
  end

  @doc """
  Applies a discount code typed by a customer, replacing any code already in the cart.

  The code is matched without regard to case or surrounding whitespace.
  Returns `{:error, :unknown_discount_code}` for a code that is not known.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_discount_code}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_discount_code(code) do
      {:ok, discount_code} -> {:ok, %{cart | discount_code: discount_code}}
      :error -> {:error, :unknown_discount_code}
    end
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the amount to pay for the cart, in cents.

  `price_list` maps each SKU in the cart to its price in cents; a SKU missing
  from it raises `KeyError`. `"SAVE10"` takes 10% off the item subtotal, and
  `"FREESHIP"` waives the shipping fee, which every other order pays.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart, price_list)

    subtotal - discount_cents(cart, subtotal) + shipping_cents(cart)
  end

  defp parse_discount_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> :error
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(price_list, sku) end)
  end

  defp discount_cents(%__MODULE__{discount_code: :save10}, subtotal) do
    # 10% of the subtotal, rounded half up to the cent.
    div(subtotal * 10 + 50, 100)
  end

  defp discount_cents(%__MODULE__{}, _subtotal), do: 0

  defp shipping_cents(%__MODULE__{discount_code: :freeship}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_fee_cents
end

defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount_code]

  @type sku :: String.t()
  @type code :: String.t()
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: code() | nil}

  @codes ["SAVE10", "FREESHIP"]
  @shipping_fee_cents 499

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

  The item leaves the cart when `quantity` is at least the units it holds.
  Removing a SKU the cart does not hold leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    remaining = Map.get(cart.items, sku, 0) - quantity
    %{cart | items: put_remaining(cart.items, sku, remaining)}
  end

  @doc """
  Applies a discount code to the cart, replacing any code it already holds.

  The code is trimmed and upcased before it is checked, so `" save10 "` and
  `"SAVE10"` are the same code. Known codes are `"SAVE10"`, which takes 10% off
  the item subtotal, and `"FREESHIP"`, which waives the shipping fee.

  Returns `{:error, {:unknown_code, code}}` for any other code.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    case normalized do
      known when known in @codes -> {:ok, %{cart | discount_code: known}}
      unknown -> {:error, {:unknown_code, unknown}}
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
  Returns the amount to pay, in cents, for the cart.

  `price_list` maps each SKU in the cart to its unit price in cents. A SKU
  missing from it raises `KeyError`, because the cart should never hold a SKU
  the store does not sell.

  The total is the item subtotal, minus the discount, plus shipping. The discount
  rounds down to the cent, so a customer never gets more than the advertised
  percentage off. Shipping is free with `"FREESHIP"`.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart, price_list)

    subtotal - discount_cents(cart, subtotal) + shipping_cents(cart)
  end

  defp put_remaining(items, sku, remaining) when remaining > 0 do
    Map.put(items, sku, remaining)
  end

  defp put_remaining(items, sku, _none_left), do: Map.delete(items, sku)

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(price_list, sku) end)
  end

  defp discount_cents(%__MODULE__{discount_code: "SAVE10"}, subtotal), do: div(subtotal * 10, 100)
  defp discount_cents(%__MODULE__{}, _subtotal), do: 0

  defp shipping_cents(%__MODULE__{discount_code: "FREESHIP"}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_fee_cents
end

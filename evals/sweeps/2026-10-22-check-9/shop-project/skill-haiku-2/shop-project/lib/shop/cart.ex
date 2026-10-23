defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499
  @discount_codes ["SAVE10", "FREESHIP"]

  @enforce_keys [:items]
  defstruct [:items, :discount_code]

  @type sku :: String.t()
  @type discount_code :: String.t()
  @type price_list :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: discount_code() | nil}

  @doc "Returns an empty cart."
  @spec new() :: t()
  def new, do: %__MODULE__{items: %{}}

  @doc "Adds `quantity` units of `sku` to the cart."
  @spec add_item(t(), sku(), pos_integer()) :: t()
  def add_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: Map.update(cart.items, sku, quantity, &(&1 + quantity))}
  end

  @doc "Removes `quantity` units of `sku`, removing the item when no units remain."
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error -> cart
      {:ok, current} when quantity >= current -> %{cart | items: Map.delete(cart.items, sku)}
      {:ok, current} -> %{cart | items: Map.put(cart.items, sku, current - quantity)}
    end
  end

  @doc """
  Applies a discount code, replacing any code already in the cart.

  Returns `{:error, {:unknown_code, code}}` for a code that is not known.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when code in @discount_codes do
    {:ok, %{cart | discount_code: code}}
  end

  def apply_discount_code(%__MODULE__{}, code) when is_binary(code) do
    {:error, {:unknown_code, code}}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the amount to pay in cents, after the discount code and shipping.

  Raises `KeyError` when `price_list` has no price for a SKU in the cart.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart.items, price_list)

    subtotal - item_discount_cents(cart.discount_code, subtotal) +
      shipping_cents(cart.discount_code)
  end

  defp subtotal_cents(items, price_list) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(price_list, sku) end)
  end

  # Rounds the discount to the nearest cent, halves up.
  defp item_discount_cents("SAVE10", subtotal), do: div(subtotal * 10 + 50, 100)
  defp item_discount_cents(_code, _subtotal), do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

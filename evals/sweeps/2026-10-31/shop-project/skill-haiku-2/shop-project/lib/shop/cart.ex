defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, :discount_code]

  @type sku :: String.t()
  @type discount_code :: :save10 | :free_shipping
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: discount_code() | nil}
  @type price_list :: %{sku() => non_neg_integer()}

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

  Removing at least as many units as the cart holds removes the item. A SKU that
  is not in the cart leaves the cart unchanged.
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
  Applies a discount code typed by the customer.

  The code is trimmed and matched without regard to case. `"SAVE10"` takes 10%
  off the item subtotal and `"FREESHIP"` waives the shipping fee. A cart holds
  one code, so a new code replaces the old one. Unknown codes are rejected.
  """
  @spec apply_discount_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    with {:ok, discount_code} <- parse_discount_code(normalize_code(code)) do
      {:ok, %{cart | discount_code: discount_code}}
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
  Returns the amount to pay in cents.

  `prices` maps each SKU in the cart to its unit price in cents. The item
  subtotal has the discount applied, rounded to the nearest cent, and the
  shipping fee of 499 cents is added unless `"FREESHIP"` is applied. A SKU
  missing from `prices` raises `KeyError`.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    subtotal - discount_cents(cart.discount_code, subtotal) + shipping_cents(cart.discount_code)
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(_discount_code, _subtotal), do: 0

  defp shipping_cents(:free_shipping), do: 0
  defp shipping_cents(_discount_code), do: @shipping_fee_cents

  defp normalize_code(code) do
    code
    |> String.trim()
    |> String.upcase()
  end

  defp parse_discount_code("SAVE10"), do: {:ok, :save10}
  defp parse_discount_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount_code(other), do: {:error, {:unknown_code, other}}
end

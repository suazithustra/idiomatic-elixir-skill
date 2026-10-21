defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping | nil
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount()}

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

  Removes the item entirely when `quantity` is at least the units held.
  Returns the cart unchanged when `sku` is not in the cart.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error -> cart
      {:ok, held} when quantity >= held -> %{cart | items: Map.delete(cart.items, sku)}
      {:ok, held} -> %{cart | items: Map.put(cart.items, sku, held - quantity)}
    end
  end

  @doc """
  Applies a discount code typed by a customer, replacing any code already applied.

  The code is trimmed and compared without case. `"SAVE10"` takes 10% off the
  item subtotal and `"FREESHIP"` waives the shipping fee.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount_code(code) do
      {:ok, %{cart | discount: discount}}
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
  Returns the order total in cents.

  `price_list` maps each SKU in the cart to its unit price in cents. A SKU
  missing from `price_list` raises `KeyError`. Shipping is 499 cents unless
  `"FREESHIP"` is applied.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    discounted_subtotal(cart.discount, subtotal_cents(cart, price_list)) +
      shipping_cents(cart.discount)
  end

  defp parse_discount_code(code) do
    case String.upcase(String.trim(code)) do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :free_shipping}
      _ -> {:error, :unknown_code}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(price_list, sku) end)
  end

  # Rounds the discount to the nearest cent, halves up.
  defp discounted_subtotal(:save10, subtotal), do: subtotal - div(subtotal * 10 + 50, 100)
  defp discounted_subtotal(_discount, subtotal), do: subtotal

  defp shipping_cents(:free_shipping), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :code]

  @type sku :: String.t()
  @type prices :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: String.t() | nil}

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

  The item is removed entirely when `quantity` is at least the units held.
  Removing a SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    remaining = Map.get(cart.items, sku, 0) - quantity

    items =
      if remaining > 0,
        do: Map.put(cart.items, sku, remaining),
        else: Map.delete(cart.items, sku)

    %{cart | items: items}
  end

  @doc """
  Applies a discount code typed by a customer.

  The code is trimmed and upper-cased before it is checked. A cart holds one
  code, so applying a second code replaces the first. Returns
  `{:error, :unknown_code}` for any code not listed in `@codes`.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, input) when is_binary(input) do
    code = input |> String.trim() |> String.upcase()

    if code in @codes do
      {:ok, %{cart | code: code}}
    else
      {:error, :unknown_code}
    end
  end

  @doc """
  Returns the total in cents: item subtotal, minus the discount, plus shipping.

  `prices` maps each SKU in the cart to its price in cents. Shipping is
  #{@shipping_fee_cents} cents unless "FREESHIP" is applied. "SAVE10" takes
  10% off the item subtotal, rounded to the nearest cent, halves up.
  """
  @spec total_cents(t(), prices()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - discount_cents(cart.code, subtotal) + shipping_cents(cart)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_cents("SAVE10", subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(_code, _subtotal), do: 0

  defp shipping_cents(%__MODULE__{code: "FREESHIP"}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_fee_cents
end

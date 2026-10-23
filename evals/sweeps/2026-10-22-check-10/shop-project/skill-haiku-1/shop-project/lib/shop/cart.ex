defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :code]

  @discount_codes ["SAVE10", "FREESHIP"]
  @shipping_fee 499

  @type sku :: String.t()
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: String.t() | nil}

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

  Removing at least as many units as the cart holds removes the item. A `sku`
  that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc """
  Applies a discount code typed by a customer, replacing any code already applied.

  The code is trimmed and matched without regard to case.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount_code(Shop.Cart.new(), " save10 ")
      iex> cart.code
      "SAVE10"

      iex> Shop.Cart.apply_discount_code(Shop.Cart.new(), "NOPE")
      {:error, :unknown_code}
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, input) when is_binary(input) do
    code = input |> String.trim() |> String.upcase()

    if code in @discount_codes do
      {:ok, %{cart | code: code}}
    else
      {:error, :unknown_code}
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
  Returns the amount to pay in cents, including the discount and shipping.

  `prices` maps each SKU in the cart to its price in cents. A SKU missing from
  `prices` raises `KeyError`, since the price list must cover every item.

  "SAVE10" takes 10% off the item subtotal, rounded to the nearest cent. Every
  order pays a shipping fee of 499 cents unless "FREESHIP" is applied.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart.items, prices)

    discounted_subtotal(subtotal, cart.code) + shipping_cents(cart.code)
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, held} when held > quantity -> Map.put(items, sku, held - quantity)
      {:ok, _held} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp subtotal_cents(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  defp discounted_subtotal(subtotal, "SAVE10") do
    subtotal - div(subtotal * 10 + 50, 100)
  end

  defp discounted_subtotal(subtotal, _code), do: subtotal

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @shipping_fee
end

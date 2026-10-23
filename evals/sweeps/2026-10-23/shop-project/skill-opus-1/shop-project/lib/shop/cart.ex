defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499
  @save10_percent_off 10

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping
  @type price_list :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount() | nil}

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

  Removing as many units as the cart holds, or more, removes the item.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 3)
      iex> Shop.Cart.remove_item(cart, "APPLE", 1).items
      %{"APPLE" => 2}
      iex> Shop.Cart.remove_item(cart, "APPLE", 5).items
      %{}
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc """
  Applies a discount code the customer typed.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. Codes are case-sensitive. Returns
  `{:error, {:unknown_discount_code, code}}` for any other code, and
  `{:error, :discount_already_applied}` when the cart already holds a code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, :discount_already_applied}
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "HALFOFF")
      {:error, {:unknown_discount_code, "HALFOFF"}}
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()}
          | {:error, {:unknown_discount_code, String.t()} | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_discount(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the total price in cents.

  The total is the item subtotal, less 10% with `"SAVE10"`, plus a shipping
  fee of 499 cents unless `"FREESHIP"` is applied. The 10% discount is rounded
  to the nearest cent, with half a cent rounded up.

  `prices` maps each SKU to its price in cents. A SKU in the cart that is
  missing from `prices` raises `KeyError`.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 250})
      999
      iex> {:ok, cart} = Shop.Cart.apply_discount(cart, "FREESHIP")
      iex> Shop.Cart.total(cart, %{"APPLE" => 250})
      500
  """
  @spec total(t(), price_list()) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    subtotal - discount_amount(subtotal, cart.discount) + shipping_fee(cart.discount)
  end

  defp remove_units(items, sku, quantity) do
    case Map.get(items, sku, 0) - quantity do
      remaining when remaining > 0 -> Map.put(items, sku, remaining)
      _no_units_left -> Map.delete(items, sku)
    end
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount(code), do: {:error, {:unknown_discount_code, code}}

  defp subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_amount(subtotal, :save10), do: div(subtotal * @save10_percent_off + 50, 100)
  defp discount_amount(_subtotal, _discount), do: 0

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

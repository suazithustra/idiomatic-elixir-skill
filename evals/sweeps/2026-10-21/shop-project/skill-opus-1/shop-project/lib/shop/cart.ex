defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @shipping_fee 499
  @save10_percent_off 10

  @type sku :: String.t()
  @type discount :: :ten_percent_off | :free_shipping
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
    remaining = Map.get(cart.items, sku, 0) - quantity
    %{cart | items: put_quantity(cart.items, sku, remaining)}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Applies the discount code a customer entered.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. Codes are case-sensitive. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :ten_percent_off
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, {:discount_already_applied, :ten_percent_off}}
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "HALFOFF")
      {:error, {:unknown_discount_code, "HALFOFF"}}
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()}
          | {:error, {:unknown_discount_code, String.t()}}
          | {:error, {:discount_already_applied, discount()}}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount_code(code),
         :ok <- ensure_no_discount(cart) do
      {:ok, %{cart | discount: discount}}
    end
  end

  @doc """
  Returns the total price in cents, including shipping.

  `prices` maps each SKU to its unit price in cents and must contain every
  SKU in the cart; a missing price raises `KeyError`. The `"SAVE10"` discount
  is rounded to the nearest cent, halves up. Every order pays a shipping fee
  of #{@shipping_fee} cents unless `"FREESHIP"` is applied.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 3)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 1000})
      3499
      iex> {:ok, cart} = Shop.Cart.apply_discount(cart, "SAVE10")
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 1000})
      3199
  """
  @spec total_price(t(), price_list()) :: non_neg_integer()
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    subtotal - item_discount(cart.discount, subtotal) + shipping_fee(cart.discount)
  end

  defp put_quantity(items, sku, quantity) when quantity > 0, do: Map.put(items, sku, quantity)
  defp put_quantity(items, sku, _quantity), do: Map.delete(items, sku)

  defp parse_discount_code("SAVE10"), do: {:ok, :ten_percent_off}
  defp parse_discount_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount_code(code), do: {:error, {:unknown_discount_code, code}}

  defp ensure_no_discount(%__MODULE__{discount: nil}), do: :ok

  defp ensure_no_discount(%__MODULE__{discount: discount}),
    do: {:error, {:discount_already_applied, discount}}

  defp subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp item_discount(:ten_percent_off, subtotal),
    do: div(subtotal * @save10_percent_off + 50, 100)

  defp item_discount(:free_shipping, _subtotal), do: 0
  defp item_discount(nil, _subtotal), do: 0

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(:ten_percent_off), do: @shipping_fee
  defp shipping_fee(nil), do: @shipping_fee
end

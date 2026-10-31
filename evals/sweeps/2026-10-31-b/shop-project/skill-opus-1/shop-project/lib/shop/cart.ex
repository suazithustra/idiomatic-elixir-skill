defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499
  @save10_percent 10

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
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

  Removing as many units as the cart holds, or more, removes the item. A `sku`
  the cart does not hold leaves the cart unchanged.

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

  @doc """
  Applies the discount code `code` to the cart.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. Codes match exactly, including case. A cart holds at most one
  code, so a cart that already holds one rejects any other code and the same
  code again.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, :discount_already_applied}
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE99")
      {:error, {:unknown_discount, "SAVE99"}}

  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :discount_already_applied | {:unknown_discount, String.t()}}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount(code) do
      {:ok, %{cart | discount: discount}}
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
  Returns the total price of the cart in cents.

  The total is the item subtotal, less any discount, plus the shipping fee of
  499 cents. An empty cart pays the fee too. `"SAVE10"` rounds the discounted
  subtotal down to a whole cent, so the customer always gets at least 10% off.

  Raises `KeyError` when `price_list` has no price for a SKU in the cart.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 250})
      999

  """
  @spec total_price(t(), price_list()) :: non_neg_integer()
  def total_price(%__MODULE__{} = cart, price_list) when is_map(price_list) do
    subtotal = item_subtotal(cart.items, price_list)
    discounted(subtotal, cart.discount) + shipping_fee(cart.discount)
  end

  defp put_quantity(items, sku, quantity) when quantity > 0, do: Map.put(items, sku, quantity)
  defp put_quantity(items, sku, _quantity), do: Map.delete(items, sku)

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :freeship}
  defp parse_discount(code), do: {:error, {:unknown_discount, code}}

  defp item_subtotal(items, price_list) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(price_list, sku) end)
  end

  defp discounted(subtotal, :save10), do: div(subtotal * (100 - @save10_percent), 100)
  defp discounted(subtotal, discount) when discount in [:freeship, nil], do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(discount) when discount in [:save10, nil], do: @shipping_fee
end

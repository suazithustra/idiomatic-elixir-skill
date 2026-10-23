defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

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
  Removing a SKU that is not in the cart leaves the cart unchanged.

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
    case Map.fetch(cart.items, sku) do
      {:ok, held} when held > quantity -> %{cart | items: %{cart.items | sku => held - quantity}}
      {:ok, _held} -> %{cart | items: Map.delete(cart.items, sku)}
      :error -> cart
    end
  end

  @doc """
  Applies the discount code a customer entered.

  Accepted codes are `"SAVE10"`, which takes 10% off the item subtotal, and
  `"FREESHIP"`, which waives the shipping fee. A cart holds at most one code.

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
          | {:error, :discount_already_applied | {:unknown_discount_code, String.t()}}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_discount(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code),
    do: {:error, :discount_already_applied}

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the total price in cents: the item subtotal after any discount,
  plus a #{@shipping_fee}-cent shipping fee unless `"FREESHIP"` is applied.

  `prices` maps each SKU to its unit price in cents and must contain every
  SKU in the cart; a missing SKU raises `KeyError`. The `"SAVE10"` discount
  is rounded to the nearest cent, halves rounding in the customer's favour.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 3)
      iex> Shop.Cart.total(cart, %{"APPLE" => 150})
      949
      iex> {:ok, cart} = Shop.Cart.apply_discount(cart, "SAVE10")
      iex> Shop.Cart.total(cart, %{"APPLE" => 150})
      904
  """
  @spec total(t(), price_list()) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    discounted_subtotal(subtotal, cart.discount) + shipping_fee(cart.discount)
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount(code), do: {:error, {:unknown_discount_code, code}}

  defp subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discounted_subtotal(subtotal, :save10), do: subtotal - div(subtotal * 10 + 50, 100)
  defp discounted_subtotal(subtotal, :free_shipping), do: subtotal
  defp discounted_subtotal(subtotal, nil), do: subtotal

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(:save10), do: @shipping_fee
  defp shipping_fee(nil), do: @shipping_fee
end

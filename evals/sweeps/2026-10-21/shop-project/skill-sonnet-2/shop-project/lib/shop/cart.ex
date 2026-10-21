defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @shipping_fee 499

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
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

  Removing at least as many units as the cart holds removes the item. A SKU
  that is not in the cart leaves the cart unchanged.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 3)
      iex> Shop.Cart.remove_item(cart, "APPLE", 2).items
      %{"APPLE" => 1}
      iex> Shop.Cart.remove_item(cart, "APPLE", 5).items
      %{}
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
  Applies a discount code, given as the string a customer typed.

  Known codes are `"SAVE10"` (10% off the item subtotal) and `"FREESHIP"`
  (no shipping fee). A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, :discount_already_applied}
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_discount, "BOGUS"}}
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :discount_already_applied | {:unknown_discount, String.t()}}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code),
    do: {:error, :discount_already_applied}

  @doc """
  Returns the total price in cents: item subtotal, less any `"SAVE10"`
  discount (rounded to the nearest cent, halves up), plus shipping.

  `prices` maps each SKU to its price in cents. A SKU missing from `prices`
  returns `{:error, {:unknown_sku, sku}}`.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 300})
      {:ok, 1099}
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal(cart, prices) do
      {:ok, subtotal - discount_amount(cart.discount, subtotal) + shipping_fee(cart.discount)}
    end
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :freeship}
  defp parse_discount(code), do: {:error, {:unknown_discount, code}}

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case Map.fetch(prices, sku) do
        {:ok, price} -> {:cont, {:ok, sum + price * quantity}}
        :error -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp discount_amount(:save10, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_amount(_discount, _subtotal), do: 0

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

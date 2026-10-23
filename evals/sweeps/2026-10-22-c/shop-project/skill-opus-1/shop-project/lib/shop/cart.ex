defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499
  @save10_percent_paid 90

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping
  @type prices :: %{sku() => non_neg_integer()}
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
  Removing an item the cart does not hold leaves the cart unchanged.

  ## Examples

      iex> cart = Shop.Cart.new() |> Shop.Cart.add_item("APPLE", 3)
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
  Applies the discount code a customer typed.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, {:discount_already_applied, :save10}}
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "HALFOFF")
      {:error, {:unknown_discount_code, "HALFOFF"}}

  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()}
          | {:error, {:unknown_discount_code, String.t()}}
          | {:error, {:discount_already_applied, discount()}}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_discount_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_discount(%__MODULE__{discount: discount}, code) when is_binary(code) do
    {:error, {:discount_already_applied, discount}}
  end

  @doc """
  Returns the total price of the cart in cents, shipping included.

  `prices` maps every SKU in the cart to its unit price in cents; a SKU
  missing from it raises `KeyError`. `"SAVE10"` rounds the discounted
  subtotal to the nearest cent, halves up.

  ## Examples

      iex> cart = Shop.Cart.new() |> Shop.Cart.add_item("APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 150})
      799

  """
  @spec total(t(), prices()) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    discounted_subtotal(subtotal, cart.discount) + shipping_fee(cart.discount)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp parse_discount_code("SAVE10"), do: {:ok, :save10}
  defp parse_discount_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount_code(code), do: {:error, {:unknown_discount_code, code}}

  defp subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discounted_subtotal(subtotal, :save10), do: div(subtotal * @save10_percent_paid + 50, 100)
  defp discounted_subtotal(subtotal, :free_shipping), do: subtotal
  defp discounted_subtotal(subtotal, nil), do: subtotal

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(:save10), do: @shipping_fee
  defp shipping_fee(nil), do: @shipping_fee
end

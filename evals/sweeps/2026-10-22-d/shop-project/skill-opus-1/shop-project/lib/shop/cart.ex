defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499
  @save10_percent 10

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
  Applies the discount code `code`, as typed by the customer.

  Accepted codes are `"SAVE10"`, 10% off the item subtotal, and
  `"FREESHIP"`, which waives the shipping fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, :discount_already_applied}
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "HALFOFF")
      {:error, {:unknown_discount, "HALFOFF"}}

  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()}
          | {:error, :discount_already_applied | {:unknown_discount, String.t()}}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount(code),
         :ok <- ensure_no_discount(cart) do
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
  Returns the total price in cents: the item subtotal, less any discount,
  plus a shipping fee of 499 cents unless shipping is waived.

  `prices` maps each SKU to its price in cents and must hold every SKU in the
  cart. The `"SAVE10"` discount is rounded down to a whole cent.

  ## Examples

      iex> cart = Shop.Cart.new() |> Shop.Cart.add_item("APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 150})
      799

  """
  @spec total(t(), price_list()) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    subtotal - item_discount(cart.discount, subtotal) + shipping_fee(cart.discount)
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount(code), do: {:error, {:unknown_discount, code}}

  defp ensure_no_discount(%__MODULE__{discount: nil}), do: :ok
  defp ensure_no_discount(%__MODULE__{}), do: {:error, :discount_already_applied}

  defp subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp item_discount(:save10, subtotal), do: div(subtotal * @save10_percent, 100)
  defp item_discount(_discount, _subtotal), do: 0

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

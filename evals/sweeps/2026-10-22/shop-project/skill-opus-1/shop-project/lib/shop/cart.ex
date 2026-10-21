defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499

  @type sku :: String.t()
  @type discount :: :ten_percent_off | :free_shipping
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
  Removing a SKU the cart does not hold returns the cart unchanged.

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
  Applies the discount code a customer entered.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. Codes are case-sensitive. A cart holds at most one code, so
  applying a second one returns `{:error, :discount_already_applied}`.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "FREESHIP")
      iex> cart.discount
      :free_shipping
      iex> Shop.Cart.apply_discount(cart, "SAVE10")
      {:error, :discount_already_applied}
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "HALFOFF")
      {:error, {:unknown_discount_code, "HALFOFF"}}
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()}
          | {:error, :discount_already_applied | {:unknown_discount_code, String.t()}}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount_code(code),
         :ok <- check_no_discount(cart) do
      {:ok, %{cart | discount: discount}}
    end
  end

  @doc """
  Returns the total price of the cart in cents.

  `prices` maps each SKU to its unit price in cents and must hold every SKU in
  the cart; a missing price raises `KeyError`. The total is the item subtotal,
  less the discount, plus a shipping fee of #{@shipping_fee} cents unless the
  `"FREESHIP"` code is applied. The `"SAVE10"` discount is rounded to the
  nearest cent, with half a cent going to the customer.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 1000})
      2499
      iex> {:ok, cart} = Shop.Cart.apply_discount(cart, "SAVE10")
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 1000})
      2299
  """
  @spec total_price(t(), prices()) :: non_neg_integer()
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    subtotal - item_discount(cart.discount, subtotal) + shipping_fee(cart.discount)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp remove_units(items, sku, quantity) do
    case items do
      %{^sku => held} when held > quantity -> %{items | sku => held - quantity}
      %{} -> Map.delete(items, sku)
    end
  end

  defp parse_discount_code("SAVE10"), do: {:ok, :ten_percent_off}
  defp parse_discount_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount_code(code), do: {:error, {:unknown_discount_code, code}}

  defp check_no_discount(%__MODULE__{discount: nil}), do: :ok
  defp check_no_discount(%__MODULE__{}), do: {:error, :discount_already_applied}

  defp subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  # 10% rounded to the nearest cent, halves up, so the half cent goes to the customer.
  defp item_discount(:ten_percent_off, subtotal), do: div(subtotal * 10 + 50, 100)
  defp item_discount(:free_shipping, _subtotal), do: 0
  defp item_discount(nil, _subtotal), do: 0

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(:ten_percent_off), do: @shipping_fee
  defp shipping_fee(nil), do: @shipping_fee
end

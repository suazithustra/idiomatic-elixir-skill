defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @shipping_fee_cents 499
  @save10_percent_off 10

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping
  @type discount_error :: :discount_already_applied | {:unknown_discount_code, String.t()}
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

  Removing as many units as the cart holds, or more, removes the item. Removing
  a SKU the cart does not hold leaves the cart unchanged.

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

    if remaining > 0 do
      %{cart | items: Map.put(cart.items, sku, remaining)}
    else
      %{cart | items: Map.delete(cart.items, sku)}
    end
  end

  @doc """
  Applies a discount code, as typed by the customer, to the cart.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the shipping
  fee. Codes match exactly. A cart holds at most one code, so once it has one,
  every further code returns `{:error, :discount_already_applied}`.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, :discount_already_applied}

      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE50")
      {:error, {:unknown_discount_code, "SAVE50"}}

  """
  @spec apply_discount(t(), String.t()) :: {:ok, t()} | {:error, discount_error()}
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
  Returns the price of the cart in cents, given `prices`, which maps each SKU to
  its price in cents.

  The total is the item subtotal, less any `"SAVE10"` discount, plus the shipping
  fee of 499 cents unless `"FREESHIP"` is applied. A discounted subtotal rounds
  down to a whole cent. Raises `KeyError` if a SKU in the cart has no price.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 150})
      799

  """
  @spec total_price(t(), price_list()) :: non_neg_integer()
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = item_subtotal(cart.items, prices)
    discounted(subtotal, cart.discount) + shipping_fee(cart.discount)
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount(code), do: {:error, {:unknown_discount_code, code}}

  defp item_subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  defp discounted(subtotal, :save10), do: div(subtotal * (100 - @save10_percent_off), 100)
  defp discounted(subtotal, :free_shipping), do: subtotal
  defp discounted(subtotal, nil), do: subtotal

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(:save10), do: @shipping_fee_cents
  defp shipping_fee(nil), do: @shipping_fee_cents
end

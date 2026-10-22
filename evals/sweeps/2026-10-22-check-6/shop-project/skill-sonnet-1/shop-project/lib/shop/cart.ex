defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee_cents 499

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount() | nil}
  @type prices :: %{sku() => non_neg_integer()}

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
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc """
  Applies a discount code, as typed by a customer, to the cart.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_code, "BOGUS"}}
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, :discount_already_applied}
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()} | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  @doc """
  Computes the total price of the cart in cents.

  `prices` maps each SKU to its price in cents. The item subtotal is reduced by
  `"SAVE10"` (rounded to the nearest cent) and a shipping fee of
  #{@shipping_fee_cents} cents is added unless `"FREESHIP"` is applied.

  ## Examples

      iex> prices = %{"APPLE" => 100}
      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 3)
      iex> Shop.Cart.total_cents(cart, prices)
      {:ok, 799}
      iex> Shop.Cart.total_cents(cart, %{})
      {:error, {:unknown_sku, "APPLE"}}
  """
  @spec total_cents(t(), prices()) :: {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_cents(%__MODULE__{} = cart, prices) do
    case subtotal_cents(cart.items, prices) do
      {:ok, subtotal} -> {:ok, discounted_subtotal(subtotal, cart.discount) + shipping(cart)}
      {:error, _reason} = error -> error
    end
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

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(code), do: {:error, {:unknown_code, code}}

  defp subtotal_cents(items, prices) do
    case Enum.find(Map.keys(items), &(not is_map_key(prices, &1))) do
      nil -> {:ok, Enum.sum_by(items, fn {sku, quantity} -> prices[sku] * quantity end)}
      sku -> {:error, {:unknown_sku, sku}}
    end
  end

  defp discounted_subtotal(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping(%__MODULE__{discount: :freeship}), do: 0
  defp shipping(%__MODULE__{}), do: @shipping_fee_cents
end

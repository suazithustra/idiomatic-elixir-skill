defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, :discount]

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

  Removing as many units as the cart holds, or more, removes the item.
  A SKU that is not in the cart leaves the cart unchanged.

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

  defp remove_units(items, sku, quantity) do
    case items do
      %{^sku => held} when held > quantity -> %{items | sku => held - quantity}
      %{^sku => _held} -> Map.delete(items, sku)
      %{} -> items
    end
  end

  @doc """
  Applies a discount code, as typed by a customer, to the cart.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount_code(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount_code(cart, "FREESHIP")
      {:error, :discount_already_applied}
      iex> Shop.Cart.apply_discount_code(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_discount_code, "BOGUS"}}
  """
  @spec apply_discount_code(t(), String.t()) ::
          {:ok, t()} | {:error, :discount_already_applied | {:unknown_discount_code, String.t()}}
  def apply_discount_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_discount(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_discount_code(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :freeship}
  defp parse_discount(code), do: {:error, {:unknown_discount_code, code}}

  @doc """
  Computes the total price in cents, given a map of SKU to price in cents.

  The 10% from `"SAVE10"` is rounded down to a whole cent. Every order pays
  a shipping fee of 499 cents unless `"FREESHIP"` is applied.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 100})
      {:ok, 699}
      iex> Shop.Cart.total(cart, %{})
      {:error, {:unknown_sku, "APPLE"}}
  """
  @spec total(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    case subtotal(cart, prices) do
      {:ok, subtotal} -> {:ok, discounted(subtotal, cart.discount) + shipping_fee(cart.discount)}
      {:error, _reason} = error -> error
    end
  end

  defp subtotal(cart, prices) do
    case Enum.find(Map.keys(cart.items), &(not is_map_key(prices, &1))) do
      nil -> {:ok, Enum.sum_by(cart.items, fn {sku, quantity} -> prices[sku] * quantity end)}
      sku -> {:error, {:unknown_sku, sku}}
    end
  end

  defp discounted(subtotal, :save10), do: div(subtotal * 90, 100)
  defp discounted(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end
end

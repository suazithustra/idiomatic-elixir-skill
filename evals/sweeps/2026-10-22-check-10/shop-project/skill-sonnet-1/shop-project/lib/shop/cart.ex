defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499
  @save10_percent 10

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type t :: %__MODULE__{
          items: %{sku() => pos_integer()},
          discount: discount() | nil
        }
  @type price_list :: %{sku() => non_neg_integer()}

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

  Removing at least as many units as the cart holds removes the item.
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

  @doc """
  Applies a discount code, as typed by a customer, to the cart.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_code(cart, "FREESHIP")
      {:error, :code_already_applied}
      iex> Shop.Cart.apply_code(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_code, "BOGUS"}}
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :code_already_applied | {:unknown_code, String.t()}}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  @doc """
  Computes the total price in cents, shipping included.

  `prices` maps each SKU to its price in cents. Returns an error naming a
  SKU in the cart that has no price.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 100})
      {:ok, 699}
      iex> Shop.Cart.total_price(cart, %{})
      {:error, {:unknown_sku, "APPLE"}}
  """
  @spec total_price(t(), price_list()) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_price(%__MODULE__{} = cart, prices) do
    with {:ok, subtotal} <- subtotal(cart, prices) do
      {:ok, discounted(subtotal, cart.discount) + shipping_fee(cart.discount)}
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
    case Map.fetch(items, sku) do
      {:ok, held} when held > quantity -> Map.put(items, sku, held - quantity)
      {:ok, _held} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(other), do: {:error, {:unknown_code, other}}

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case Map.fetch(prices, sku) do
        {:ok, price} -> {:cont, {:ok, sum + price * quantity}}
        :error -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  # The discount is rounded to the nearest cent, halves up.
  defp discounted(subtotal, :save10), do: subtotal - div(subtotal * @save10_percent + 50, 100)
  defp discounted(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

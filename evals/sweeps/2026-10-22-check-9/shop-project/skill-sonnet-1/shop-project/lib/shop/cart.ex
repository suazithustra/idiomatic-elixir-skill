defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping
  @type t :: %__MODULE__{
          items: %{sku() => pos_integer()},
          discount: discount() | nil
        }

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
  def remove_item(%__MODULE__{items: items} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case items do
      %{^sku => held} when held > quantity ->
        %{cart | items: Map.put(items, sku, held - quantity)}

      %{^sku => _held} ->
        %{cart | items: Map.delete(items, sku)}

      %{} ->
        cart
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

  @doc """
  Computes the total price of the cart in cents.

  `prices` maps each SKU to its price in cents. The total is the item subtotal,
  less any `"SAVE10"` discount (rounded to the nearest cent, halves up), plus a
  499 cent shipping fee unless `"FREESHIP"` is applied.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 100})
      {:ok, 699}
      iex> Shop.Cart.total_price(cart, %{})
      {:error, {:missing_price, "APPLE"}}
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:missing_price, sku()}}
  def total_price(%__MODULE__{} = cart, prices) do
    case subtotal(cart.items, prices) do
      {:ok, subtotal} -> {:ok, discounted(subtotal, cart.discount) + shipping_fee(cart.discount)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_discount(code), do: {:error, {:unknown_discount_code, code}}

  defp subtotal(items, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case Map.fetch(prices, sku) do
        {:ok, price} -> {:cont, {:ok, sum + price * quantity}}
        :error -> {:halt, {:error, {:missing_price, sku}}}
      end
    end)
  end

  defp discounted(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp discounted(subtotal, _discount), do: subtotal

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

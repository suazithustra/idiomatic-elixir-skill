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

  Removing as many units as the cart holds, or more, removes the item.
  A SKU that is not in the cart leaves the cart unchanged.

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
    case cart.items do
      %{^sku => held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      %{^sku => _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      %{} ->
        cart
    end
  end

  @doc """
  Applies a discount code, given as the customer typed it.

  "SAVE10" takes 10% off the item subtotal and "FREESHIP" waives the
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
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  @doc """
  Computes the total price in cents, shipping included.

  `prices` maps each SKU to its price in cents. The "SAVE10" discount is
  rounded down to a whole cent. Fails when the cart holds a SKU the price
  list does not know.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 300})
      {:ok, 1099}
      iex> Shop.Cart.total_price(cart, %{})
      {:error, {:unknown_sku, "APPLE"}}
  """
  @spec total_price(t(), price_list()) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    case subtotal(cart, prices) do
      {:ok, subtotal} -> {:ok, discounted(subtotal, cart.discount) + shipping_fee(cart.discount)}
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

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(code), do: {:error, {:unknown_code, code}}

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case Map.fetch(prices, sku) do
        {:ok, price} -> {:cont, {:ok, sum + price * quantity}}
        :error -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp discounted(subtotal, :save10), do: div(subtotal * 90, 100)
  defp discounted(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

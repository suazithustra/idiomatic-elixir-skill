defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
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

  Removing at least as many units as the cart holds removes the item.
  A SKU that is not in the cart leaves the cart unchanged.
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
  Applies a discount code, given as the string a customer typed.

  A cart holds at most one code. "SAVE10" takes 10% off the item subtotal and
  "FREESHIP" waives the shipping fee.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10

      iex> Shop.Cart.apply_code(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_code, "BOGUS"}}
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()} | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  @doc """
  Computes the total price in cents, given a map of SKU to unit price in cents.

  The total is the item subtotal, less the "SAVE10" discount if applied
  (rounded down to a whole cent), plus a shipping fee of 499 cents unless
  "FREESHIP" is applied. Returns an error if a SKU has no price.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 100})
      {:ok, 699}

      iex> Shop.Cart.total(Shop.Cart.new(), %{})
      {:ok, 499}
  """
  @spec total(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal(cart, prices) do
      {:ok, apply_discount(subtotal, cart.discount) + shipping_fee(cart.discount)}
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(other), do: {:error, {:unknown_code, other}}

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, subtotal} ->
      case Map.fetch(prices, sku) do
        {:ok, price} -> {:cont, {:ok, subtotal + price * quantity}}
        :error -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp apply_discount(subtotal, :save10), do: div(subtotal * 90, 100)
  defp apply_discount(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

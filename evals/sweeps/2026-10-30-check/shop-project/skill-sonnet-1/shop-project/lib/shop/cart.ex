defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499

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

  Removing as many units as the cart holds, or more, removes the item.
  A `sku` that is not in the cart leaves the cart unchanged.

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
    items =
      case cart.items do
        %{^sku => held} when held > quantity ->
          %{cart.items | sku => held - quantity}

        %{} ->
          Map.delete(cart.items, sku)
      end

    %{cart | items: items}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Applies a discount code, as typed by the customer, to the cart.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_code(cart, "FREESHIP")
      {:error, :code_already_applied}
      iex> Shop.Cart.apply_code(Shop.Cart.new(), "BOGUS")
      {:error, :unknown_code}
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_code(%__MODULE__{}, _code), do: {:error, :code_already_applied}

  @doc """
  Returns the total price in cents, given a map of SKU to price in cents.

  The total is the item subtotal, less any discount, plus the shipping fee
  of #{@shipping_fee} cents unless `"FREESHIP"` is applied. A 10% discount is
  rounded to the nearest cent, halves up.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 300})
      {:ok, 1099}
      iex> Shop.Cart.total(cart, %{})
      {:error, {:unknown_sku, "APPLE"}}
  """
  @spec total(t(), prices()) :: {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) do
    with {:ok, subtotal} <- subtotal(cart.items, prices) do
      {:ok, apply_discount(subtotal, cart.discount) + shipping_fee(cart.discount)}
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_code), do: {:error, :unknown_code}

  defp subtotal(items, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case Map.fetch(prices, sku) do
        {:ok, price} -> {:cont, {:ok, sum + price * quantity}}
        :error -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp apply_discount(subtotal, :save10), do: subtotal - div(subtotal * 10 + 50, 100)
  defp apply_discount(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @shipping_fee 499
  @save10_percent_paid 90

  @enforce_keys [:items]
  defstruct [:discount, items: %{}]

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

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Removes `quantity` units of `sku` from the cart.

  Removing at least as many units as the cart holds removes the item.
  A SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      {:ok, _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      :error ->
        cart
    end
  end

  @doc """
  Applies a discount code, as typed by a customer, to the cart.

  Supported codes are `"SAVE10"` (10% off the item subtotal) and
  `"FREESHIP"` (no shipping fee). A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10

      iex> Shop.Cart.apply_code(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_code, "BOGUS"}}

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> Shop.Cart.apply_code(cart, "FREESHIP")
      {:error, :code_already_applied}
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()} | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_code(%__MODULE__{}, _code), do: {:error, :code_already_applied}

  @doc """
  Returns the total price of the cart in cents, shipping included.

  `prices` maps each SKU to its price in cents. Raises `KeyError` if the
  cart holds a SKU missing from `prices`. The `"SAVE10"` discount is
  rounded to the nearest cent, halves up.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 300})
      1099
  """
  @spec total(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) do
    discounted_subtotal(cart, prices) + shipping_fee(cart)
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(other), do: {:error, {:unknown_code, other}}

  defp discounted_subtotal(%__MODULE__{discount: :save10} = cart, prices) do
    div(subtotal(cart, prices) * @save10_percent_paid + 50, 100)
  end

  defp discounted_subtotal(%__MODULE__{} = cart, prices), do: subtotal(cart, prices)

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp shipping_fee(%__MODULE__{discount: :freeship}), do: 0
  defp shipping_fee(%__MODULE__{}), do: @shipping_fee
end

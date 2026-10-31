defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

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

  Removing at least as many units as the cart holds removes the item, and
  removing a SKU the cart does not hold leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    items =
      case cart.items do
        %{^sku => held} when held > quantity ->
          Map.put(cart.items, sku, held - quantity)

        %{} ->
          Map.delete(cart.items, sku)
      end

    %{cart | items: items}
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
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()} | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  @doc """
  Returns the total price in cents, given a map of SKU to price in cents.

  The total is the item subtotal, less any percentage discount, plus the
  shipping fee unless the cart holds `"FREESHIP"`. Raises `KeyError` when a
  SKU in the cart has no price.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total_price(cart, %{"APPLE" => 100})
      699
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_price(%__MODULE__{} = cart, prices) do
    subtotal =
      Enum.sum_by(cart.items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)

    discounted_subtotal(subtotal, cart.discount) + shipping_fee(cart.discount)
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

  # 10% off, rounded to the nearest cent with halves up.
  defp discounted_subtotal(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

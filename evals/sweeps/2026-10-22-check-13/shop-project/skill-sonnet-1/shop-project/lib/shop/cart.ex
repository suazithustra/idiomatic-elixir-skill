defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
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

  Removing as many units as the cart holds, or more, removes the item.
  A SKU that is not in the cart is ignored.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    items =
      case Map.fetch(cart.items, sku) do
        {:ok, held} when held > quantity -> Map.put(cart.items, sku, held - quantity)
        {:ok, _held} -> Map.delete(cart.items, sku)
        :error -> cart.items
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
  Applies a discount code, as typed by a customer, to the cart.

  "SAVE10" takes 10% off the item subtotal and "FREESHIP" waives the
  shipping fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10

      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_discount_code, "BOGUS"}}

  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_discount_code, String.t()} | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_discount(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  @doc """
  Returns the total price of the cart in cents.

  `prices` maps each SKU to its price in cents and must hold every SKU in
  the cart, otherwise `KeyError` is raised. The shipping fee is added after
  any discount on the item subtotal, which is rounded to the nearest cent.
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_price(%__MODULE__{} = cart, prices) do
    subtotal =
      Enum.sum_by(cart.items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)

    discounted_subtotal(subtotal, cart.discount) + shipping_fee(cart.discount)
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :freeship}
  defp parse_discount(code), do: {:error, {:unknown_discount_code, code}}

  defp discounted_subtotal(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

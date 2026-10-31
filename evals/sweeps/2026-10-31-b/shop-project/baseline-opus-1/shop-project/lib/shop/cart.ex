defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type price_list :: %{sku() => non_neg_integer()}
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

  The item leaves the cart when no units remain, including when `quantity` is
  more than the cart holds. A `sku` that is not in the cart changes nothing.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.get(cart.items, sku, 0) - quantity do
      remaining when remaining > 0 -> %{cart | items: Map.put(cart.items, sku, remaining)}
      _none_left -> %{cart | items: Map.delete(cart.items, sku)}
    end
  end

  @doc """
  Applies a discount code typed by a customer.

  "SAVE10" takes 10% off the item subtotal and "FREESHIP" waives the shipping
  fee. Codes must match exactly. A cart that already holds a discount rejects
  every further code.
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code) do
    {:error, :code_already_applied}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the order total in cents: the item subtotal less any discount, plus
  shipping.

  The 10% discount is rounded to the nearest cent, with half a cent rounding up.
  Raises `KeyError` if `prices` has no price for a SKU in the cart.
  """
  @spec total(t(), price_list()) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)

    subtotal - discount_cents(cart.discount, subtotal) + shipping_cents(cart.discount)
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_code), do: {:error, :unknown_code}

  defp subtotal(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal + 5, 10)
  defp discount_cents(_discount, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

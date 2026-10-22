defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee_cents 499
  @save10_percent 10

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

  Removes the item entirely when `quantity` is at least the units it holds.
  Removing an SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Applies a discount code, replacing any code already in the cart.

  Codes are matched without regard to surrounding spaces or letter case.
  Returns `{:error, {:unknown_code, code}}` for a code that is not recognized.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the amount the customer pays, in cents.

  `prices` maps each SKU in the cart to its unit price in cents. A SKU missing
  from `prices` raises, because a priced cart must cover every item in it.

  The total is the item subtotal, less any discount, plus the shipping fee.
  "SAVE10" takes 10% off the subtotal, rounded to the nearest cent. "FREESHIP"
  waives the shipping fee.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart.items, prices)

    subtotal - discount_cents(cart.discount, subtotal) + shipping_cents(cart.discount)
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, current} when current > quantity -> Map.put(items, sku, current - quantity)
      {:ok, _current} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp parse_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> {:error, {:unknown_code, code}}
    end
  end

  defp subtotal_cents(items, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * @save10_percent + 50, 100)
  defp discount_cents(discount, _subtotal) when discount in [nil, :freeship], do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

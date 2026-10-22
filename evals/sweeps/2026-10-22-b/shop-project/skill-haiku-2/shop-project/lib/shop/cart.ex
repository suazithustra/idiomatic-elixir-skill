defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499
  @save10_percent 10

  @enforce_keys [:items]
  defstruct [:items, code: nil]

  @type sku :: String.t()
  @type code :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: code() | nil}

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

  Removing at least as many units as the cart holds removes the item. Removing
  a SKU the cart does not hold leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc """
  Applies a discount code typed by a customer, replacing any code already in the cart.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the shipping
  fee. Any other string returns `{:error, {:unknown_code, code}}`.
  """
  @spec apply_discount_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, parsed} -> {:ok, %{cart | code: parsed}}
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

  @doc """
  Returns the amount to charge in cents: the item subtotal less the discount,
  plus the shipping fee.

  `prices` maps each SKU in the cart to its price in cents. A SKU missing from
  `prices` raises `KeyError`, because a cart cannot hold an unpriced item.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - discount_cents(cart.code, subtotal) + shipping_fee_cents(cart)
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, held} when held > quantity -> Map.put(items, sku, held - quantity)
      {:ok, _held} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  # Integer arithmetic: a float percentage would round unpredictably.
  defp discount_cents(:save10, subtotal), do: div(subtotal * @save10_percent + 50, 100)
  defp discount_cents(_code, _subtotal), do: 0

  defp shipping_fee_cents(%__MODULE__{code: :freeship}), do: 0
  defp shipping_fee_cents(%__MODULE__{}), do: @shipping_fee_cents

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(other), do: {:error, {:unknown_code, other}}
end

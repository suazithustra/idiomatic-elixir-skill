defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :code]

  @shipping_fee_cents 499

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

  The item is removed entirely when `quantity` is at least the units in the cart.
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
  Applies a discount code typed by a customer, replacing any code already in the cart.

  Codes are matched case-insensitively, ignoring surrounding whitespace.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_code(%__MODULE__{} = cart, input) when is_binary(input) do
    case parse_code(input) do
      {:ok, code} -> {:ok, %{cart | code: code}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the amount the customer pays, in cents.

  The total is the item subtotal minus the discount from the cart's code, plus
  the shipping fee. `prices` maps each SKU in the cart to its unit price in cents;
  a missing SKU raises, because the price list is incomplete. The discount is
  rounded down to a whole cent.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - discount_cents(subtotal, cart.code) + shipping_cents(cart)
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, current} when current > quantity -> Map.put(items, sku, current - quantity)
      {:ok, _current} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp parse_code(input) do
    case input |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      other -> {:error, {:unknown_code, other}}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_cents(_subtotal, nil), do: 0
  defp discount_cents(subtotal, :save10), do: div(subtotal * 10, 100)
  defp discount_cents(_subtotal, :freeship), do: 0

  defp shipping_cents(%__MODULE__{code: :freeship}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_fee_cents
end

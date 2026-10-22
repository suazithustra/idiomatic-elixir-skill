defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499
  @discount_codes ["SAVE10", "FREESHIP"]

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @type sku :: String.t()
  @type price_list :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: String.t() | nil}

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
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc """
  Applies a discount code, replacing any code already applied.

  Codes are matched without regard to case or surrounding whitespace.
  """
  @spec apply_discount(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    case normalize_code(code) do
      {:ok, normalized} -> {:ok, %{cart | discount: normalized}}
      :error -> {:error, {:unknown_code, code}}
    end
  end

  @doc """
  Returns the total price of the cart in cents, including shipping.

  `prices` maps each SKU in the cart to its price in cents. A SKU missing
  from `prices` raises `KeyError`.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    items_cents = subtotal - discount_cents(cart.discount, subtotal)

    items_cents + shipping_cents(cart.discount)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, held} when held > quantity -> Map.put(items, sku, held - quantity)
      {:ok, _held} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp normalize_code(code) do
    case code |> String.trim() |> String.upcase() do
      normalized when normalized in @discount_codes -> {:ok, normalized}
      _unknown -> :error
    end
  end

  defp subtotal_cents(cart, prices) do
    Enum.sum_by(cart.items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  # Rounds half up to the nearest cent.
  defp discount_cents("SAVE10", subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(_other_code, _subtotal), do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_other_code), do: @shipping_fee_cents
end

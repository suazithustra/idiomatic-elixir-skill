defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499
  @known_codes ~w(SAVE10 FREESHIP)

  @enforce_keys [:items]
  defstruct [:items, discount_code: nil]

  @type sku :: String.t()
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: String.t() | nil}

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

  Removes the item entirely when `quantity` is at least the units held.
  Does nothing if `sku` is not in the cart.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error -> cart
      {:ok, held} when quantity >= held -> %{cart | items: Map.delete(cart.items, sku)}
      {:ok, held} -> %{cart | items: Map.put(cart.items, sku, held - quantity)}
    end
  end

  @doc """
  Applies a discount code, replacing any code already on the cart.

  The code is trimmed and matched case-insensitively. Returns
  `{:error, :unknown_code}` for codes that are not recognised.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    if normalized in @known_codes do
      {:ok, %{cart | discount_code: normalized}}
    else
      {:error, :unknown_code}
    end
  end

  @doc """
  Returns the order total in cents.

  `prices` maps each SKU in the cart to its unit price in cents. Raises
  `KeyError` if a SKU has no price. The total is the item subtotal, minus any
  item discount, plus the shipping fee. "SAVE10" takes 10% off the subtotal,
  rounded down to whole cents. "FREESHIP" waives the shipping fee.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - item_discount_cents(cart.discount_code, subtotal) +
      shipping_cents(cart.discount_code)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + Map.fetch!(prices, sku) * quantity
    end)
  end

  defp item_discount_cents("SAVE10", subtotal), do: div(subtotal * 10, 100)
  defp item_discount_cents(_code, _subtotal), do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

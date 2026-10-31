defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499
  @codes ["SAVE10", "FREESHIP"]

  @enforce_keys [:items]
  defstruct [:items, :code]

  @type sku :: String.t()
  @type code :: String.t()
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

  Removing as many units as the cart holds, or more, removes the item. A `sku`
  that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, held} when quantity < held ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      {:ok, _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      :error ->
        cart
    end
  end

  @doc """
  Applies a discount code, replacing any code already applied.

  The code is matched without regard to case or surrounding spaces. Returns
  `{:error, :unknown_code}` when the code is not one the shop accepts.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case normalize_code(code) do
      {:ok, normalized} -> {:ok, %{cart | code: normalized}}
      :error -> {:error, :unknown_code}
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
  Returns the amount due in cents.

  `prices` maps each SKU in the cart to its price in cents. `"SAVE10"` takes
  10% off the item subtotal, rounded to the nearest cent with halves rounded
  up. A shipping fee of 499 cents is added unless the code is `"FREESHIP"`.

  Raises `KeyError` when the cart holds a SKU that `prices` does not list.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - item_discount_cents(cart.code, subtotal) + shipping_fee_cents(cart.code)
  end

  defp normalize_code(code) do
    normalized = code |> String.trim() |> String.upcase()

    if normalized in @codes, do: {:ok, normalized}, else: :error
  end

  defp subtotal_cents(cart, prices) do
    Enum.sum_by(cart.items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp item_discount_cents("SAVE10", subtotal), do: div(subtotal * 10 + 50, 100)
  defp item_discount_cents(_code, _subtotal), do: 0

  defp shipping_fee_cents("FREESHIP"), do: 0
  defp shipping_fee_cents(_code), do: @shipping_fee_cents
end

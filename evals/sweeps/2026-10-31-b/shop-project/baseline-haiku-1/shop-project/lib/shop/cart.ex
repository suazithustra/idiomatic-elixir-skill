defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount_code: nil]

  @type sku :: String.t()
  @type price_list :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: String.t() | nil}

  @shipping_fee_cents 499
  @discount_codes ~w(SAVE10 FREESHIP)

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

  The item is removed entirely when `quantity` is at least the number of units
  in the cart. Removing an SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    items =
      case Map.fetch(cart.items, sku) do
        {:ok, current} when current > quantity -> Map.put(cart.items, sku, current - quantity)
        {:ok, _current} -> Map.delete(cart.items, sku)
        :error -> cart.items
      end

    %{cart | items: items}
  end

  @doc """
  Sets the cart's discount code, replacing any code already applied.

  The code is trimmed and matched case-insensitively. Unknown codes return
  `{:error, :unknown_code}` and leave the cart unchanged.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    if normalized in @discount_codes do
      {:ok, %{cart | discount_code: normalized}}
    else
      {:error, :unknown_code}
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
  Returns the amount to pay in cents.

  `price_list` maps each SKU in the cart to its unit price in cents. The
  "SAVE10" code takes 10% off the item subtotal, rounded down to a whole cent.
  Shipping is 499 cents unless the "FREESHIP" code is applied.

  Raises `KeyError` if a SKU in the cart is missing from `price_list`.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart, price_list)

    subtotal - discount_cents(cart.discount_code, subtotal) + shipping_cents(cart.discount_code)
  end

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + Map.fetch!(price_list, sku) * quantity
    end)
  end

  defp discount_cents("SAVE10", subtotal), do: div(subtotal * 10, 100)
  defp discount_cents(_code, _subtotal), do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount_code: nil]

  @type sku :: String.t()
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: String.t() | nil}

  @shipping_fee_cents 499
  @known_codes ["SAVE10", "FREESHIP"]

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
  Removes `quantity` units of `sku` from the cart. Removing at least as many
  units as the cart holds removes the item. A SKU not in the cart leaves it unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error -> cart
      {:ok, current} when quantity >= current -> %{cart | items: Map.delete(cart.items, sku)}
      {:ok, current} -> %{cart | items: Map.put(cart.items, sku, current - quantity)}
    end
  end

  @doc """
  Applies a discount code typed by a customer. Surrounding whitespace and case
  are ignored. A cart holds at most one code, so a valid code replaces the
  previous one. Unknown codes return `{:error, :unknown_code}` and leave the cart unchanged.
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

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the order total in cents. `prices` maps each SKU in the cart to its
  unit price in cents. Raises `KeyError` if a SKU in the cart has no price.

  SAVE10 takes 10% off the item subtotal, rounded down to a whole cent.
  Shipping is 499 cents unless FREESHIP is applied.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    subtotal - discount_cents(cart.discount_code, subtotal) + shipping_cents(cart.discount_code)
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + quantity * Map.fetch!(prices, sku)
    end)
  end

  defp discount_cents("SAVE10", subtotal), do: div(subtotal * 10, 100)
  defp discount_cents(_code, _subtotal), do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

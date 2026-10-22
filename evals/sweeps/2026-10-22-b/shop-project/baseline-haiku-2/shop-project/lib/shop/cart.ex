defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount_code: nil]

  @shipping_fee_cents 499
  @discount_codes ["SAVE10", "FREESHIP"]

  @type sku :: String.t()
  @type t :: %__MODULE__{
          items: %{sku() => pos_integer()},
          discount_code: String.t() | nil
        }
  @type price_list :: %{sku() => non_neg_integer()}

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
  units as the cart holds removes the item entirely.
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

  @doc """
  Applies a discount code typed by a customer. Codes are matched without
  regard to case or surrounding whitespace. A cart holds one code at a time,
  so this replaces any code already applied.
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

  @doc """
  Returns the amount due in cents: the item subtotal less any discount, plus
  the shipping fee unless the cart has the "FREESHIP" code. `prices` maps each
  SKU in the cart to its price in cents.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - discount_cents(cart, subtotal) + shipping_cents(cart)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, sum ->
      sum + quantity * Map.fetch!(prices, sku)
    end)
  end

  # SAVE10 takes 10% off; the discount is rounded down to a whole cent.
  defp discount_cents(%__MODULE__{discount_code: "SAVE10"}, subtotal), do: div(subtotal * 10, 100)
  defp discount_cents(%__MODULE__{}, _subtotal), do: 0

  defp shipping_cents(%__MODULE__{discount_code: "FREESHIP"}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_fee_cents
end

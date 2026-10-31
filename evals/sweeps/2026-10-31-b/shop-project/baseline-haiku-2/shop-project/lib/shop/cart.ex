defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, discount_code: nil]

  @type sku :: String.t()
  @type discount_code :: :save10 | :freeship
  @type t :: %__MODULE__{
          items: %{sku() => pos_integer()},
          discount_code: discount_code() | nil
        }

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

  Removes the item entirely when `quantity` is at least the number of units
  in the cart. Does nothing if the SKU is not in the cart.
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
  Applies a discount code, replacing any code already on the cart.

  Codes are matched case-insensitively, ignoring surrounding whitespace.
  Returns `{:error, :unknown_code}` for any code other than "SAVE10" or
  "FREESHIP".
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_discount_code(code) do
      {:ok, discount_code} -> {:ok, %{cart | discount_code: discount_code}}
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
  Returns the order total in cents.

  `prices` maps each SKU in the cart to its unit price in cents. The total is
  the item subtotal minus any discount, plus a shipping fee of 499 cents.
  "SAVE10" takes 10% off the item subtotal, rounding the discount down to a
  whole cent. "FREESHIP" waives the shipping fee.

  Raises `KeyError` if a SKU in the cart is missing from `prices`.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - discount_cents(cart.discount_code, subtotal) + shipping_cents(cart.discount_code)
  end

  defp parse_discount_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> :error
    end
  end

  defp subtotal_cents(cart, prices) do
    Enum.reduce(cart.items, 0, fn {sku, quantity}, acc ->
      acc + quantity * Map.fetch!(prices, sku)
    end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * 10, 100)
  defp discount_cents(_discount_code, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount_code), do: @shipping_fee_cents
end

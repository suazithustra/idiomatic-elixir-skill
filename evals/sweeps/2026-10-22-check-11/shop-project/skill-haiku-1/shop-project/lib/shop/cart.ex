defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_cents 499

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type prices :: %{sku() => non_neg_integer()}
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

  The item leaves the cart when `quantity` is at least the units it holds.
  Removing an SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      {:ok, _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      :error ->
        cart
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
  Applies a discount code typed by a customer, replacing any code already applied.

  The code is trimmed and matched without regard to case. Accepted codes are
  `"SAVE10"`, which takes 10% off the item subtotal, and `"FREESHIP"`, which
  waives the shipping fee. An unknown code returns `{:error, {:unknown_code, code}}`.
  """
  @spec apply_discount_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the amount due in cents: the item subtotal less the discount, plus shipping.

  `prices` maps each SKU in the cart to its unit price in cents. A SKU missing
  from `prices` raises `KeyError`, because the price list must cover every item.
  Shipping is #{@shipping_cents} cents unless the cart has the `"FREESHIP"` code.
  """
  @spec total_cents(t(), prices()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    items_total = subtotal - discount_cents(cart.discount, subtotal)

    items_total + shipping_cents(cart.discount)
  end

  defp parse_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      other -> {:error, {:unknown_code, other}}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  # Adding half the divisor before dividing rounds 10% to the nearest cent, halves up.
  defp discount_cents(:save10, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(nil, _subtotal), do: 0
  defp discount_cents(:freeship, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(nil), do: @shipping_cents
  defp shipping_cents(:save10), do: @shipping_cents
end

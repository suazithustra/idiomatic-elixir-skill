defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
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

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Removes `quantity` units of `sku` from the cart.

  Removing at least as many units as the cart holds removes the item. Removing
  an item the cart does not hold leaves the cart unchanged.
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

  @doc """
  Applies a discount code, replacing the code the cart already holds.

  Codes are matched without regard to case or surrounding whitespace, since
  customers type them into a form. An unknown code returns
  `{:error, {:unknown_code, code}}` and leaves the cart as it was.
  """
  @spec apply_discount_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_discount_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      :error -> {:error, {:unknown_code, code}}
    end
  end

  @doc """
  Returns the amount to pay for the cart, in cents.

  `prices` maps each SKU to its price in cents. The discount applies to the item
  subtotal, and shipping is charged unless the cart holds `"FREESHIP"`. Raises
  `KeyError` when the cart holds a SKU that `prices` does not list.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    subtotal - discount_cents(cart.discount, subtotal) + shipping_cents(cart.discount)
  end

  defp parse_discount_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _unknown -> :error
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  # The discount is rounded half up to the nearest cent.
  defp discount_cents(:save10, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(nil, _subtotal), do: 0
  defp discount_cents(:freeship, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(nil), do: @shipping_fee
  defp shipping_cents(:save10), do: @shipping_fee
end

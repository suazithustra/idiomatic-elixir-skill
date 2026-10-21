defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount() | nil}
  @type prices :: %{sku() => non_neg_integer()}

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

  Removing as many units as the cart holds, or more, removes the item.
  A SKU that is not in the cart leaves the cart unchanged.
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
  Applies a discount code typed by a customer, replacing any code already applied.

  Codes are matched without regard to case or surrounding spaces.
  Returns `{:error, :unknown_code}` for a code that is not recognized.
  """
  @spec apply_discount(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_discount(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, :unknown_code} = error -> error
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
  Returns the amount to pay, in cents.

  `prices` maps each SKU to its unit price in cents. A SKU in the cart without
  a price raises `KeyError`, because that is a bug in the caller.

  SAVE10 takes 10% off the item subtotal, rounded to the nearest cent with halves
  rounded up. Shipping costs #{@shipping_fee_cents} cents unless FREESHIP is applied.
  """
  @spec total_cents(t(), prices()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - discount_cents(cart.discount, subtotal) + shipping_cents(cart.discount)
  end

  defp parse_discount(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _unknown -> {:error, :unknown_code}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(_discount, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

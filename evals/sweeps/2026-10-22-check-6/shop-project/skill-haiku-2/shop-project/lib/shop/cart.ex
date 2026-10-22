defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499
  @discount_codes ~w(SAVE10 FREESHIP)

  @enforce_keys [:items]
  defstruct [:items, :discount_code]

  @type sku :: String.t()
  @type prices :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{
          items: %{sku() => pos_integer()},
          discount_code: String.t() | nil
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

  Removing at least as many units as the cart holds removes the item. Removing
  a SKU that is not in the cart returns the cart unchanged.
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
  Applies a discount code, replacing any code already applied.

  The code is trimmed and matched without regard to case. Returns an error
  for a code that is not known.
  """
  @spec apply_discount_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    if normalized in @discount_codes do
      {:ok, %{cart | discount_code: normalized}}
    else
      {:error, {:unknown_code, code}}
    end
  end

  @doc """
  Returns the amount to charge, in cents, given the price in cents of each SKU.

  The subtotal is each item's price times its quantity. SAVE10 takes 10% off
  the subtotal, rounded to the nearest cent. Shipping costs 499 cents unless
  FREESHIP is applied. Raises `KeyError` if the cart holds a SKU missing from
  `prices`.
  """
  @spec total_cents(t(), prices()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    discount = discount_cents(cart.discount_code, subtotal)
    shipping = shipping_cents(cart.discount_code)

    subtotal - discount + shipping
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_cents("SAVE10", subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(code, _subtotal) when code in [nil, "FREESHIP"], do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(code) when code in [nil, "SAVE10"], do: @shipping_fee_cents
end

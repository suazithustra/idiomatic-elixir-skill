defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount_code]

  @shipping_fee_cents 499
  @save10_percent 10

  @type sku :: String.t()
  @type price_list :: %{sku() => non_neg_integer()}
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

  Removing as many units as the cart holds, or more, removes the item. Removing
  an item the cart does not hold leaves the cart unchanged.
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
  Applies a discount code, replacing the code already applied, if any.

  Codes are matched exactly. `"SAVE10"` takes 10% off the item subtotal and
  `"FREESHIP"` waives the shipping fee. Any other string returns
  `{:error, {:unknown_code, code}}`.
  """
  @spec apply_discount_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_discount_code(code) do
      {:ok, discount_code} -> {:ok, %{cart | discount_code: discount_code}}
      {:error, _reason} = error -> error
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
  Returns the amount to pay, in cents, given each SKU's price in cents.

  The discount is taken from the item subtotal, rounded to the nearest cent with
  halves rounded up. The shipping fee is added after the discount.

  Raises `KeyError` when the cart holds a SKU that has no price in `prices`.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    discount = discount_cents(cart.discount_code, subtotal)
    shipping = shipping_cents(cart.discount_code)

    subtotal - discount + shipping
  end

  defp parse_discount_code("SAVE10"), do: {:ok, :save10}
  defp parse_discount_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_discount_code(code), do: {:error, {:unknown_code, code}}

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * @save10_percent + 50, 100)
  defp discount_cents(_code, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

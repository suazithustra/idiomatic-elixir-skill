defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.

  Amounts are integer cents.
  """

  @enforce_keys [:items]
  defstruct [:items, :code]

  @shipping_fee_cents 499

  # Codes are matched as exact strings, since they arrive from a form.
  @discounts %{
    "SAVE10" => {:percent_off, 10},
    "FREESHIP" => :free_shipping
  }

  @type sku :: String.t()
  @type code :: String.t()
  @type prices :: %{sku() => non_neg_integer()}
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

  Removes the item when the cart holds no more units of it. Does nothing when
  the cart does not hold `sku`.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, current} when current > quantity ->
        %{cart | items: Map.put(cart.items, sku, current - quantity)}

      {:ok, _current} ->
        %{cart | items: Map.delete(cart.items, sku)}

      :error ->
        cart
    end
  end

  @doc """
  Applies a discount `code` to the cart, replacing any code already applied.

  Returns `{:error, {:unknown_code, code}}` when the code is not recognized.
  """
  @spec apply_code(t(), code()) :: {:ok, t()} | {:error, {:unknown_code, code()}}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case Map.fetch(@discounts, code) do
      {:ok, _discount} -> {:ok, %{cart | code: code}}
      :error -> {:error, {:unknown_code, code}}
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
  Returns the amount to pay, in cents, for the cart's items at `prices`.

  The subtotal is the price of every unit in the cart. A percentage code takes
  that share off the subtotal, rounded to the nearest cent with halves rounded
  up. Shipping costs #{@shipping_fee_cents} cents unless the code is `"FREESHIP"`.

  Raises `KeyError` when a SKU in the cart has no price in `prices`.
  """
  @spec total_cents(t(), prices()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    subtotal - discount_cents(cart, subtotal) + shipping_cents(cart)
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_cents(%__MODULE__{code: nil}, _subtotal), do: 0

  defp discount_cents(%__MODULE__{code: code}, subtotal) do
    case Map.fetch!(@discounts, code) do
      {:percent_off, percent} -> div(subtotal * percent + 50, 100)
      :free_shipping -> 0
    end
  end

  defp shipping_cents(%__MODULE__{code: "FREESHIP"}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_fee_cents
end

defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount_code]

  @shipping_fee_cents 499
  @discount_codes %{"SAVE10" => :save10, "FREESHIP" => :free_shipping}

  @type sku :: String.t()
  @type discount_code :: :save10 | :free_shipping
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

  Removing at least as many units as the cart holds removes the item. Removing
  an SKU that is not in the cart returns the cart unchanged.
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

  The code is trimmed and matched without regard to case. Returns
  `{:error, {:unknown_code, code}}` for a code that is not recognized.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case Map.fetch(@discount_codes, normalize_code(code)) do
      {:ok, discount_code} -> {:ok, %{cart | discount_code: discount_code}}
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
  Returns the amount to charge in cents.

  `prices` maps each SKU in the cart to its unit price in cents. The total is the
  item subtotal less any item discount, plus the shipping fee. A SKU missing from
  `prices` raises `KeyError`.

  ## Examples

      iex> cart = Shop.Cart.new() |> Shop.Cart.add_item("APPLE", 2)
      iex> Shop.Cart.total_cents(cart, %{"APPLE" => 150})
      799

  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    subtotal - discount_cents(cart.discount_code, subtotal) + shipping_cents(cart.discount_code)
  end

  defp normalize_code(code) do
    code
    |> String.trim()
    |> String.upcase()
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(_discount_code, _subtotal), do: 0

  defp shipping_cents(:free_shipping), do: 0
  defp shipping_cents(_discount_code), do: @shipping_fee_cents
end

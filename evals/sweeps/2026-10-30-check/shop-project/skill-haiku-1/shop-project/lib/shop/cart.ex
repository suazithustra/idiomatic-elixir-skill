defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :code]

  @shipping_cents 499
  @codes ~w(SAVE10 FREESHIP)

  @type sku :: String.t()
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: String.t() | nil}

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

  Removing at least as many units as the cart holds removes the item.
  Removing an SKU that is not in the cart leaves the cart unchanged.
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
  Applies a discount code typed by a customer.

  The code is trimmed and upper-cased before it is checked. A cart holds one
  code, so applying a second code replaces the first. Unknown codes return
  `{:error, :unknown_code}` and leave the cart as it was.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized =
      code
      |> String.trim()
      |> String.upcase()

    if normalized in @codes do
      {:ok, %{cart | code: normalized}}
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
  Returns the amount to pay, in cents.

  `price_list` maps each SKU in the cart to its unit price in cents. The total
  is the item subtotal, minus any discount, plus the shipping fee. Raises
  `KeyError` if a SKU in the cart has no price.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart, price_list)

    subtotal - discount_cents(cart, subtotal) + shipping_cents(cart)
  end

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(price_list, sku) end)
  end

  # Rounds half up to the nearest cent.
  defp discount_cents(%__MODULE__{code: "SAVE10"}, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(%__MODULE__{}, _subtotal), do: 0

  defp shipping_cents(%__MODULE__{code: "FREESHIP"}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_cents
end

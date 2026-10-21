defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @type sku :: String.t()
  @type code :: String.t()
  @type discount :: {:percent_off, pos_integer()} | :free_shipping
  @type price_list :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: code() | nil}

  @shipping_fee_cents 499

  @discounts %{
    "SAVE10" => {:percent_off, 10},
    "FREESHIP" => :free_shipping
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

  Removing at least as many units as the cart holds removes the item entirely.
  Removing a SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error ->
        cart

      {:ok, current} when quantity >= current ->
        %{cart | items: Map.delete(cart.items, sku)}

      {:ok, current} ->
        %{cart | items: Map.put(cart.items, sku, current - quantity)}
    end
  end

  @doc """
  Applies a discount code, replacing any code already on the cart.

  Codes are matched ignoring case and surrounding whitespace. Returns
  `{:error, :unknown_code}` for codes that are not recognised.
  """
  @spec apply_discount(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    if Map.has_key?(@discounts, normalized) do
      {:ok, %{cart | discount: normalized}}
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
  Returns the order total in cents.

  `prices` maps each SKU in the cart to its unit price in cents. Raises
  `KeyError` if a SKU in the cart has no price. A percentage discount is applied
  to the item subtotal and rounded down to a whole cent. The shipping fee of
  #{@shipping_fee_cents} cents is added unless the applied code waives it.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    discount = Map.get(@discounts, cart.discount)
    subtotal = subtotal_cents(cart, prices)

    subtotal - percent_off(subtotal, discount) + shipping_cents(discount)
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, sum ->
      sum + Map.fetch!(prices, sku) * quantity
    end)
  end

  defp percent_off(subtotal, {:percent_off, percent}), do: div(subtotal * percent, 100)
  defp percent_off(_subtotal, _discount), do: 0

  defp shipping_cents(:free_shipping), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

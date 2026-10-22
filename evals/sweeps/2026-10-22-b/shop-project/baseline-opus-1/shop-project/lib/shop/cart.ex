defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct items: %{}, discount: nil

  @type sku :: String.t()
  @type cents :: non_neg_integer()
  @type price_list :: %{sku() => cents()}
  @type discount :: :save10 | :free_shipping
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

  Removing as many or more units than the cart holds removes the item entirely.
  Removing a SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, held} when held > quantity -> %{cart | items: %{cart.items | sku => held - quantity}}
      {:ok, _held} -> %{cart | items: Map.delete(cart.items, sku)}
      :error -> cart
    end
  end

  @doc """
  Applies a discount code, as typed by the customer, to the cart.

  Supported codes are `"SAVE10"` (10% off the item subtotal) and `"FREESHIP"`
  (no shipping fee). A cart holds at most one code.
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code),
    do: {:error, :discount_already_applied}

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_code(_code), do: {:error, :unknown_code}

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the total price of the cart in cents, including shipping.

  `prices` maps each SKU to its unit price in cents; raises `KeyError` if a SKU
  in the cart has no price. The `"SAVE10"` discount is rounded to the nearest
  cent (half up). Shipping costs #{@shipping_fee} cents unless `"FREESHIP"` is
  applied.
  """
  @spec total(t(), price_list()) :: cents()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    subtotal - item_discount(cart.discount, subtotal) + shipping(cart.discount)
  end

  defp subtotal(items, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + Map.fetch!(prices, sku) * quantity
    end)
  end

  defp item_discount(:save10, subtotal), do: div(subtotal + 5, 10)
  defp item_discount(_discount, _subtotal), do: 0

  defp shipping(:free_shipping), do: 0
  defp shipping(_discount), do: @shipping_fee
end

defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct items: %{}, discount: nil

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping
  @type price_list :: %{sku() => non_neg_integer()}
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

  Removing at least as many units as the cart holds removes the item entirely.
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

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Applies a discount code entered by the customer.

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

  @doc """
  Returns the total price of the cart in cents, including shipping.

  `prices` maps each SKU to its unit price in cents and must contain every SKU
  in the cart; a missing SKU raises `KeyError`. The 10% discount is rounded
  down to whole cents.
  """
  @spec total(t(), price_list()) :: non_neg_integer()
  def total(%__MODULE__{items: items, discount: discount}, prices) when is_map(prices) do
    subtotal =
      Enum.reduce(items, 0, fn {sku, quantity}, acc ->
        acc + Map.fetch!(prices, sku) * quantity
      end)

    subtotal - item_discount(subtotal, discount) + shipping_fee(discount)
  end

  defp item_discount(subtotal, :save10), do: div(subtotal, 10)
  defp item_discount(_subtotal, _discount), do: 0

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

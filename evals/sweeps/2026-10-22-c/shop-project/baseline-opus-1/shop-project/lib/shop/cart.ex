defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct items: %{}, discount: nil

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
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

  Removing as many units as the cart holds, or more, removes the item entirely.
  Removing an item that is not in the cart leaves the cart unchanged.
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
  Applies a discount code entered by a customer.

  Codes are matched case-insensitively, ignoring surrounding whitespace.
  Supported codes are `"SAVE10"` (10% off the item subtotal) and `"FREESHIP"`
  (no shipping fee). A cart holds at most one code.
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      :error -> {:error, :unknown_code}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  defp parse_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> :error
    end
  end

  @doc """
  Returns the total price of the cart in cents, including shipping.

  `prices` maps each SKU to its unit price in cents and must contain every SKU
  in the cart. The `"SAVE10"` discount is rounded to the nearest cent.
  """
  @spec total(t(), price_list()) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    subtotal - item_discount(cart.discount, subtotal) + shipping_fee(cart.discount)
  end

  defp subtotal(items, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + Map.fetch!(prices, sku) * quantity
    end)
  end

  defp item_discount(:save10, subtotal), do: div(subtotal + 5, 10)
  defp item_discount(_discount, _subtotal), do: 0

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

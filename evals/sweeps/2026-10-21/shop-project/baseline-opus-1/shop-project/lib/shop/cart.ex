defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
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

  Removing at least as many units as the cart holds removes the item.
  Removing an item that is not in the cart returns the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{items: items} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.get(items, sku, 0) do
      held when held > quantity -> %{cart | items: %{items | sku => held - quantity}}
      _held -> %{cart | items: Map.delete(items, sku)}
    end
  end

  @doc """
  Applies a discount code typed by the customer.

  Known codes are `"SAVE10"` (10% off the item subtotal) and `"FREESHIP"`
  (no shipping fee). Surrounding whitespace and letter case are ignored.
  A cart holds at most one code, so applying a second code is rejected.
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the total price in cents, including shipping.

  `prices` maps each SKU to its price in cents and must cover every SKU in
  the cart; a missing price raises `KeyError`. The `"SAVE10"` discount is
  rounded down to whole cents.
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_price(%__MODULE__{items: items, discount: discount}, prices) when is_map(prices) do
    subtotal =
      Enum.reduce(items, 0, fn {sku, quantity}, acc ->
        acc + quantity * Map.fetch!(prices, sku)
      end)

    discounted_subtotal(subtotal, discount) + shipping_fee(discount)
  end

  defp parse_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> {:error, :unknown_code}
    end
  end

  defp discounted_subtotal(subtotal, :save10), do: subtotal - div(subtotal, 10)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

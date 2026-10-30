defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, :discount]

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

  The item leaves the cart when no units remain, so removing as many units as
  the cart holds, or more, removes the item. Removing a SKU that is not in the
  cart returns the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    items =
      case cart.items do
        %{^sku => held} when held > quantity -> %{cart.items | sku => held - quantity}
        items -> Map.delete(items, sku)
      end

    %{cart | items: items}
  end

  @doc """
  Applies the discount code `code` to the cart.

  Codes match exactly, so `"save10"` is unknown. A cart holds at most one
  discount, so any code is refused once one has been applied.
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
  Returns the total price of the cart in cents, shipping included.

  `prices` maps each SKU to its price in cents. Raises `KeyError` if a SKU in
  the cart has no price. `"SAVE10"` rounds its 10% to the nearest cent, with
  half a cent rounding up.
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_price(%__MODULE__{items: items, discount: discount}, prices) when is_map(prices) do
    subtotal = Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)

    subtotal - discount_amount(discount, subtotal) + shipping_fee(discount)
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_code), do: {:error, :unknown_code}

  defp discount_amount(:save10, subtotal), do: div(subtotal + 5, 10)
  defp discount_amount(_discount, _subtotal), do: 0

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

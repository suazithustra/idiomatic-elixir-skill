defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
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
  Removing a SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case cart.items do
      %{^sku => held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      %{^sku => _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      _ ->
        cart
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
  Applies a discount code, given as the customer typed it.

  Known codes are "SAVE10" (10% off the item subtotal) and "FREESHIP"
  (no shipping fee). A cart holds at most one code.
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      :error -> {:error, :unknown_code}
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code) do
    {:error, :code_already_applied}
  end

  @doc """
  Computes the total in cents, including shipping and any discount.

  `prices` maps each SKU to its price in cents. The 10% discount is rounded
  down to a whole cent. Returns an error if a SKU in the cart has no price.
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal(cart, prices) do
      {:ok, subtotal - item_discount(cart.discount, subtotal) + shipping_fee(cart.discount)}
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_), do: :error

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, acc} ->
      case prices do
        %{^sku => price} -> {:cont, {:ok, acc + price * quantity}}
        _ -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp item_discount(:save10, subtotal), do: div(subtotal * 10, 100)
  defp item_discount(_, _subtotal), do: 0

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_), do: @shipping_fee
end

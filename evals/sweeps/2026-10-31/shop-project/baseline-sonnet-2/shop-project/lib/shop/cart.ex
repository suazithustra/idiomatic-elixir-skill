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

  If the cart holds `quantity` units or fewer, the item is removed entirely.
  Removing an item that is not in the cart leaves the cart unchanged.
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
  Applies a discount code, given as the string a customer typed.

  Supported codes are `"SAVE10"` (10% off the item subtotal) and `"FREESHIP"`
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

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  @doc """
  Returns the total price in cents, including shipping.

  `prices` maps each SKU to its price in cents. The "SAVE10" discount is
  rounded down to a whole cent. Fails if the cart holds a SKU missing from
  `prices`.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_cents(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal_cents(cart, prices) do
      {:ok, apply_item_discount(subtotal, cart.discount) + shipping_cents(cart.discount)}
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_code), do: :error

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case prices do
        %{^sku => price} -> {:cont, {:ok, sum + price * quantity}}
        _ -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp apply_item_discount(subtotal, :save10), do: subtotal - div(subtotal * 10, 100)
  defp apply_item_discount(subtotal, _discount), do: subtotal

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee
end

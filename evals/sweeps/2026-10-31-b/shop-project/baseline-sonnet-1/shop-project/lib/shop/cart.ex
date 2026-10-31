defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount() | nil}
  @type prices :: %{sku() => non_neg_integer()}

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
  Applies a discount code, as typed by the customer, to the cart.

  Known codes are `"SAVE10"` and `"FREESHIP"`. A cart holds at most one code,
  so applying a second one is rejected.
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  @doc """
  Computes the total price in cents, including shipping.

  `prices` maps each SKU to its unit price in cents. `"SAVE10"` takes 10% off
  the item subtotal (the discount is rounded down to a whole cent), and
  `"FREESHIP"` waives the 499 cent shipping fee. Returns an error if a SKU in
  the cart has no price.
  """
  @spec total_price(t(), prices()) :: {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal(cart, prices) do
      {:ok, subtotal - discount_cents(cart, subtotal) + shipping_cents(cart)}
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_code), do: {:error, :unknown_code}

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, acc} ->
      case prices do
        %{^sku => price} -> {:cont, {:ok, acc + price * quantity}}
        _ -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp discount_cents(%__MODULE__{discount: :save10}, subtotal), do: div(subtotal, 10)
  defp discount_cents(%__MODULE__{}, _subtotal), do: 0

  defp shipping_cents(%__MODULE__{discount: :freeship}), do: 0
  defp shipping_cents(%__MODULE__{}), do: @shipping_fee_cents
end

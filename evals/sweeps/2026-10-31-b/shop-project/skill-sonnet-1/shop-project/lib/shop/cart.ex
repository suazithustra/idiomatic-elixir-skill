defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type t :: %__MODULE__{
          items: %{sku() => pos_integer()},
          discount: discount() | nil
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

  Removing as many units as the cart holds, or more, removes the item.
  A SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Applies a discount code, as typed by a customer, to the cart.

  A cart holds at most one code. The codes are `"SAVE10"` (10% off the item
  subtotal) and `"FREESHIP"` (no shipping fee).
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_code(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :code_already_applied}
  end

  @doc """
  Returns the total price of the cart in cents, shipping included.

  `prices` maps each SKU to its price in cents. The 10% discount is rounded
  down to a whole cent. Every order pays a shipping fee of #{@shipping_fee}
  cents unless `"FREESHIP"` is applied.
  """
  @spec total(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) do
    with {:ok, subtotal} <- subtotal(cart, prices) do
      {:ok, subtotal - item_discount(cart.discount, subtotal) + shipping_fee(cart.discount)}
    end
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, held} when held > quantity ->
        Map.put(items, sku, held - quantity)

      {:ok, _held} ->
        Map.delete(items, sku)

      :error ->
        items
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_code), do: {:error, :unknown_code}

  defp subtotal(cart, prices) do
    with :ok <- check_priced(cart, prices) do
      {:ok, Enum.sum_by(cart.items, fn {sku, quantity} -> prices[sku] * quantity end)}
    end
  end

  defp check_priced(cart, prices) do
    case Enum.find(Map.keys(cart.items), &(not is_map_key(prices, &1))) do
      nil ->
        :ok

      sku ->
        {:error, {:unknown_sku, sku}}
    end
  end

  defp item_discount(:save10, subtotal), do: div(subtotal * 10, 100)
  defp item_discount(discount, _subtotal) when discount in [nil, :freeship], do: 0

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(discount) when discount in [nil, :save10], do: @shipping_fee
end

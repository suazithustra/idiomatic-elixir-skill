defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499

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
  A SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{items: items} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(items, sku, quantity)}
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

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. A cart holds at most one code.
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()} | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount(code) do
      {:ok, %{cart | discount: discount}}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code) do
    {:error, :discount_already_applied}
  end

  @doc """
  Computes the total price of the cart in cents, given a price list that maps
  each SKU to its price in cents.

  The 10% from `"SAVE10"` is rounded to the nearest cent, halves up. Every
  order pays a shipping fee of #{@shipping_fee} cents unless `"FREESHIP"` is applied.
  """
  @spec total(t(), prices()) :: {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal(cart, prices) do
      {:ok, discounted_subtotal(subtotal, cart.discount) + shipping_fee(cart.discount)}
    end
  end

  defp remove_units(items, sku, quantity) do
    case items do
      %{^sku => held} when held > quantity -> Map.put(items, sku, held - quantity)
      %{} -> Map.delete(items, sku)
    end
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :freeship}
  defp parse_discount(code), do: {:error, {:unknown_code, code}}

  defp subtotal(%__MODULE__{items: items}, prices) do
    case Enum.find(Map.keys(items), &(not is_map_key(prices, &1))) do
      nil -> {:ok, Enum.sum_by(items, fn {sku, quantity} -> prices[sku] * quantity end)}
      sku -> {:error, {:unknown_sku, sku}}
    end
  end

  defp discounted_subtotal(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

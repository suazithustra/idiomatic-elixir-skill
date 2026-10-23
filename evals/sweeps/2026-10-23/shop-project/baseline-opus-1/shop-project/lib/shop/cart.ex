defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @shipping_fee 499

  @discount_codes %{"SAVE10" => :save10, "FREESHIP" => :free_shipping}

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

  Removing at least as many units as the cart holds removes the item.
  Removing an item that is not in the cart returns the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case cart.items do
      %{^sku => held} when held > quantity ->
        %{cart | items: %{cart.items | sku => held - quantity}}

      _ ->
        %{cart | items: Map.delete(cart.items, sku)}
    end
  end

  @doc """
  Applies a discount code as typed by the customer.

  `"SAVE10"` takes 10% off the item subtotal and `"FREESHIP"` waives the
  shipping fee. Codes are matched ignoring case and surrounding whitespace.
  A cart holds at most one code, so applying a second one is rejected.
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :discount_already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    case Map.fetch(@discount_codes, normalized) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      :error -> {:error, :unknown_code}
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
  Returns the total price in cents: the item subtotal, less any discount,
  plus a #{@shipping_fee}-cent shipping fee unless `"FREESHIP"` is applied.

  `prices` maps each SKU to its unit price in cents and must contain every
  SKU in the cart; a missing price raises `KeyError`. The 10% discount is
  rounded to the nearest cent, with half cents going to the customer.
  An empty cart is not an order, so its total is 0.
  """
  @spec total(t(), price_list()) :: non_neg_integer()
  def total(%__MODULE__{items: items}, prices) when map_size(items) == 0 and is_map(prices),
    do: 0

  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal = subtotal(cart.items, prices)
    subtotal - item_discount(cart.discount, subtotal) + shipping_fee(cart.discount)
  end

  defp subtotal(items, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + quantity * Map.fetch!(prices, sku)
    end)
  end

  defp item_discount(:save10, subtotal), do: div(subtotal + 5, 10)
  defp item_discount(_discount, _subtotal), do: 0

  defp shipping_fee(:free_shipping), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

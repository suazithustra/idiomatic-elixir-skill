defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @codes %{"SAVE10" => :save10, "FREESHIP" => :free_shipping}

  @enforce_keys [:items]
  defstruct [:items, code: nil]

  @type sku :: String.t()
  @type code :: :save10 | :free_shipping
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: code() | nil}
  @type price_list :: %{sku() => non_neg_integer()}

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
  Removing an SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: update_units(cart.items, sku, quantity)}
  end

  @doc """
  Applies a discount code typed by a customer.

  The code is trimmed and matched case-insensitively. Applying a code replaces
  any code already on the cart. Unknown codes return `{:error, :unknown_code}`.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, input) when is_binary(input) do
    case Map.fetch(@codes, input |> String.trim() |> String.upcase()) do
      {:ok, code} -> {:ok, %{cart | code: code}}
      :error -> {:error, :unknown_code}
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
  Returns the amount to pay in cents.

  `price_list` maps each SKU in the cart to its unit price in cents. Raises
  `KeyError` if a SKU in the cart has no price. `SAVE10` takes 10% off the item
  subtotal, rounding the discount down to a whole cent. Shipping costs
  #{@shipping_fee_cents} cents unless `FREESHIP` is applied.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart, price_list)
    shipping = shipping_cents(cart.code)

    discounted_subtotal(cart.code, subtotal) + shipping
  end

  defp update_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, current} when current > quantity -> Map.put(items, sku, current - quantity)
      {:ok, _current} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    Enum.reduce(items, 0, fn {sku, quantity}, sum ->
      sum + Map.fetch!(price_list, sku) * quantity
    end)
  end

  defp discounted_subtotal(:save10, subtotal), do: subtotal - div(subtotal * 10, 100)
  defp discounted_subtotal(_code, subtotal), do: subtotal

  defp shipping_cents(:free_shipping), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

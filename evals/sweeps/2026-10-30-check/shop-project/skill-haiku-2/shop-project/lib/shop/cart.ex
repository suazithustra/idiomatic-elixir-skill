defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee_cents 499

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping
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

  The item leaves the cart when `quantity` is at least the units it holds.
  An `sku` that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      {:ok, _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      :error ->
        cart
    end
  end

  @doc """
  Applies a discount code typed by a customer, replacing any code already applied.

  Codes ignore letter case and surrounding whitespace. Returns
  `{:error, :unknown_code}` for a code the shop does not recognize.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized =
      code
      |> String.trim()
      |> String.upcase()

    case parse_code(normalized) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, :unknown_code} = error -> error
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
  Returns the amount the customer pays, in cents.

  `prices` maps each SKU in the cart to its price in cents. A SAVE10 code takes
  10% off the item subtotal, rounded to the nearest cent. Shipping costs 499 cents
  unless the FREESHIP code is applied.

  Raises `KeyError` when the cart holds a SKU that has no price.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    discount = discount_cents(cart.discount, subtotal)

    subtotal - discount + shipping_cents(cart.discount)
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_code(_code), do: {:error, :unknown_code}

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * 10 + 50, 100)
  defp discount_cents(_discount, _subtotal), do: 0

  defp shipping_cents(:free_shipping), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

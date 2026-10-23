defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, code: nil]

  @codes ~w(SAVE10 FREESHIP)
  @standard_shipping_cents 499

  @type sku :: String.t()
  @type code :: String.t()
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: code() | nil}

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

  The item is removed entirely when the cart holds no more than `quantity`
  units of it. Removing an SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error ->
        cart

      {:ok, current} when current > quantity ->
        %{cart | items: Map.put(cart.items, sku, current - quantity)}

      {:ok, _current} ->
        %{cart | items: Map.delete(cart.items, sku)}
    end
  end

  @doc """
  Applies a discount code typed by a customer, replacing any code already applied.

  The code is trimmed and case-insensitive. Unknown codes are rejected and leave
  the cart unchanged.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, input) when is_binary(input) do
    code = input |> String.trim() |> String.upcase()

    if code in @codes do
      {:ok, %{cart | code: code}}
    else
      {:error, :unknown_code}
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
  Returns the amount due in cents.

  `prices` maps each SKU in the cart to its unit price in cents; a SKU missing
  from `prices` raises `KeyError`. The subtotal is discounted by the applied code
  (a discount is rounded down to whole cents), then the shipping fee is added
  unless the code is "FREESHIP".
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{items: items, code: code}, prices) do
    subtotal =
      Enum.reduce(items, 0, fn {sku, quantity}, sum ->
        sum + quantity * Map.fetch!(prices, sku)
      end)

    subtotal - discount_cents(subtotal, code) + shipping_cents(code)
  end

  defp discount_cents(subtotal, "SAVE10"), do: div(subtotal * 10, 100)
  defp discount_cents(_subtotal, _code), do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @standard_shipping_cents
end

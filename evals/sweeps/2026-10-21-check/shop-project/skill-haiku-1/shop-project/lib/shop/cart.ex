defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @shipping_fee_cents 499

  @type sku :: String.t()
  @type discount :: :save10 | :freeship | nil
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount()}
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
  Removing an SKU that is not in the cart leaves the cart unchanged.
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

  Codes ignore case and surrounding spaces. Returns `{:error, :unknown_code}`
  for any code other than `"SAVE10"` or `"FREESHIP"`.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the total in cents to charge the customer.

  The subtotal is each item's quantity times its price in `prices`. SAVE10
  takes 10% off the subtotal, rounded down to the cent. Shipping is 499 cents
  unless FREESHIP is applied.

  Raises `KeyError` if an SKU in the cart is missing from `prices`.
  """
  @spec total_cents(t(), prices()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)
    subtotal - discount_cents(cart.discount, subtotal) + shipping_cents(cart.discount)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp parse_code(code) do
    normalized = code |> String.trim() |> String.upcase()

    case normalized do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> {:error, :unknown_code}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal * 10, 100)
  defp discount_cents(_discount, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

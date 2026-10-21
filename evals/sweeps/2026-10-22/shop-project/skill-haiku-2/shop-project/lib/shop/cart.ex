defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, code: nil]

  @type sku :: String.t()
  @type code :: :save10 | :freeship
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

  Removing at least as many units as the cart holds removes the item.
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
  Applies a discount code typed by a customer, replacing any code already applied.

  Codes ignore case and surrounding whitespace. Unknown codes return an error and leave the cart unchanged.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.new() |> Shop.Cart.apply_code(" save10 ")
      iex> cart.code
      :save10

      iex> Shop.Cart.new() |> Shop.Cart.apply_code("BOGUS")
      {:error, {:unknown_code, "BOGUS"}}
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_code(%__MODULE__{} = cart, input) when is_binary(input) do
    case parse_code(input) do
      {:ok, code} -> {:ok, %{cart | code: code}}
      :error -> {:error, {:unknown_code, input}}
    end
  end

  @doc """
  Returns the amount to charge in cents: the item subtotal after any discount, plus shipping.

  `price_list` maps each SKU in the cart to its price in cents. A SKU missing from the
  price list raises `KeyError`, because a cart should never hold an unpriced item.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart.items, price_list)
    discounted_subtotal(subtotal, cart.code) + shipping_cents(cart.code)
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, current} when current > quantity -> Map.put(items, sku, current - quantity)
      {:ok, _current} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp parse_code(input) do
    case input |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> :error
    end
  end

  defp subtotal_cents(items, price_list) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(price_list, sku) * quantity end)
  end

  # Rounds to the nearest cent, halves up, so the customer never gets a fractional cent.
  defp discounted_subtotal(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp discounted_subtotal(subtotal, _code), do: subtotal

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

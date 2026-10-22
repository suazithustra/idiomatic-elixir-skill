defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @enforce_keys [:items]
  defstruct [:items, discount_code: nil]

  @type sku :: String.t()
  @type discount_code :: String.t() | nil
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: discount_code()}

  @shipping_fee_cents 499
  @discount_codes ~w(SAVE10 FREESHIP)

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
  Removes `quantity` units of `sku` from the cart. Removing at least as many
  units as the cart holds removes the item entirely.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error ->
        cart

      {:ok, current} when quantity >= current ->
        %{cart | items: Map.delete(cart.items, sku)}

      {:ok, current} ->
        %{cart | items: Map.put(cart.items, sku, current - quantity)}
    end
  end

  @doc """
  Applies a discount code typed by a customer. The code is trimmed and matched
  case-insensitively. A cart holds at most one code, so applying a code replaces
  any code already on the cart.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    if normalized in @discount_codes do
      {:ok, %{cart | discount_code: normalized}}
    else
      {:error, :unknown_code}
    end
  end

  @doc """
  Returns the amount due in cents: the item subtotal less any discount, plus the
  shipping fee unless the cart has the "FREESHIP" code.

  `price_list` maps each SKU in the cart to its unit price in cents.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    subtotal = subtotal_cents(cart, price_list)

    subtotal - discount_cents(cart.discount_code, subtotal) + shipping_cents(cart.discount_code)
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp subtotal_cents(cart, price_list) do
    Enum.reduce(cart.items, 0, fn {sku, quantity}, sum ->
      sum + quantity * Map.fetch!(price_list, sku)
    end)
  end

  defp discount_cents("SAVE10", subtotal), do: div(subtotal * 10, 100)
  defp discount_cents(_code, _subtotal), do: 0

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

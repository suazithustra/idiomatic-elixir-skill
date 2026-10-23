defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @shipping_fee_cents 499

  @discount_codes %{"SAVE10" => :save10, "FREESHIP" => :freeship}

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
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
  Removes `quantity` units of `sku` from the cart. Removing at least as many
  units as the cart holds removes the item entirely.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, current} when current > quantity ->
        %{cart | items: Map.put(cart.items, sku, current - quantity)}

      {:ok, _current} ->
        %{cart | items: Map.delete(cart.items, sku)}

      :error ->
        cart
    end
  end

  @doc """
  Applies a discount code, replacing any code already on the cart. Codes are
  matched ignoring case and surrounding whitespace.
  """
  @spec apply_discount(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    case Map.fetch(@discount_codes, code |> String.trim() |> String.upcase()) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
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
  Returns the amount to pay in cents, given a price list that maps each SKU
  to its unit price in cents.

  SAVE10 takes 10% off the item subtotal, rounding the discount down to a whole
  cent. Shipping is charged unless FREESHIP is applied.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, price_list) do
    cart
    |> subtotal_cents(price_list)
    |> discounted_cents(cart.discount)
    |> Kernel.+(shipping_cents(cart.discount))
  end

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + quantity * Map.fetch!(price_list, sku)
    end)
  end

  defp discounted_cents(subtotal, :save10), do: subtotal - div(subtotal, 10)
  defp discounted_cents(subtotal, _discount), do: subtotal

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

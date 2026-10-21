defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @type sku :: String.t()
  @type discount :: :save10 | :freeship | nil
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount()}
  @type price_list :: %{sku() => non_neg_integer()}

  @shipping_fee_cents 499

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

  Removes the item entirely when `quantity` is at least the units held.
  Does nothing when `sku` is not in the cart.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      {:ok, held} when quantity >= held -> %{cart | items: Map.delete(cart.items, sku)}
      {:ok, held} -> %{cart | items: Map.put(cart.items, sku, held - quantity)}
      :error -> cart
    end
  end

  @doc """
  Applies a discount code typed by a customer.

  Codes ignore case and surrounding spaces. The cart holds one code, so a
  valid code replaces the one already applied. Returns
  `{:error, :unknown_code}` for any code other than `"SAVE10"` or `"FREESHIP"`.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, %{cart | discount: :save10}}
      "FREESHIP" -> {:ok, %{cart | discount: :freeship}}
      _unknown -> {:error, :unknown_code}
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
  Returns the amount to pay, in cents, using `prices` to map each SKU to its
  unit price in cents.

  `"SAVE10"` takes 10% off the item subtotal, rounded to the nearest cent with
  halves rounded up. Every order pays a flat shipping fee of 499 cents, which
  `"FREESHIP"` waives.

  Raises `KeyError` when the cart holds a SKU that is missing from `prices`.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    discounted_subtotal(subtotal, cart.discount) + shipping_cents(cart.discount)
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  defp discounted_subtotal(subtotal, :save10), do: subtotal - div(subtotal * 10 + 50, 100)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

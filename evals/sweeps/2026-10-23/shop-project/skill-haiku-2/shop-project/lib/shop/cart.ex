defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee_cents 499

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
  Removes `quantity` units of `sku` from the cart.

  Removing at least as many units as the cart holds removes the item.
  Removing a SKU that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error -> cart
      {:ok, held} when quantity >= held -> %{cart | items: Map.delete(cart.items, sku)}
      {:ok, held} -> %{cart | items: Map.put(cart.items, sku, held - quantity)}
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
  Applies a discount code typed by a customer, replacing any code already applied.

  Codes are matched without regard to surrounding spaces or letter case.
  Returns `{:error, :unknown_code}` for a code that is not recognized.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.new() |> Shop.Cart.apply_code(" save10 ")
      iex> cart.discount
      :save10

      iex> Shop.Cart.new() |> Shop.Cart.apply_code("BOGUS")
      {:error, :unknown_code}
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the amount to pay, in cents, for the cart.

  `prices` maps each SKU in the cart to its unit price in cents. A SKU missing
  from `prices` raises `KeyError`. A discount applies to the item subtotal;
  shipping is added after it unless the discount waives it.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    discounted_cents(subtotal, cart.discount) + shipping_cents(cart.discount)
  end

  defp parse_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> {:error, :unknown_code}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  # Takes 10% off, rounding half up to the nearest cent.
  defp discounted_cents(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp discounted_cents(subtotal, _discount), do: subtotal

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

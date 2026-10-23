defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, :code]

  @codes ~w(SAVE10 FREESHIP)
  @shipping_cents 499

  @type sku :: String.t()
  @type prices :: %{sku() => non_neg_integer()}
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: String.t() | nil}

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

  Removes the item entirely when the cart holds `quantity` units or fewer.
  Does nothing when the SKU is not in the cart.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %{cart | items: remove_units(cart.items, sku, quantity)}
  end

  @doc """
  Applies a discount code, replacing any code already in the cart.

  The code is trimmed and upper-cased before it is checked, so `" save10 "`
  is accepted. Returns `{:error, :unknown_code}` for a code that is not known.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.new() |> Shop.Cart.apply_code("save10")
      iex> cart.code
      "SAVE10"

      iex> Shop.Cart.apply_code(Shop.Cart.new(), "BOGUS")
      {:error, :unknown_code}
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    if normalized in @codes do
      {:ok, %{cart | code: normalized}}
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
  Returns the amount to pay, in cents.

  `prices` maps each SKU in the cart to its price in cents. The subtotal is
  the sum of quantity times price. `"SAVE10"` takes 10% off the subtotal, and
  shipping of #{@shipping_cents} cents is added unless the code is `"FREESHIP"`.

  Raises `KeyError` when a SKU in the cart has no price, since that is a
  catalog bug.
  """
  @spec total_cents(t(), prices()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    cart
    |> subtotal_cents(prices)
    |> discount(cart.code)
    |> Kernel.+(shipping_cents(cart.code))
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, held} when held > quantity -> Map.put(items, sku, held - quantity)
      {:ok, _held} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(prices, sku) end)
  end

  # Keeps 90% of the subtotal, rounded to the nearest cent with halves up.
  defp discount(subtotal, "SAVE10"), do: div(subtotal * 90 + 50, 100)
  defp discount(subtotal, _code), do: subtotal

  defp shipping_cents("FREESHIP"), do: 0
  defp shipping_cents(_code), do: @shipping_cents
end

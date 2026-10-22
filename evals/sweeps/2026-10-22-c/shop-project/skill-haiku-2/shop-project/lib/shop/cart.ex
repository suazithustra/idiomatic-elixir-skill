defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, :discount]

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

  The item is removed entirely when the cart holds no more units of it than
  `quantity`. A `sku` that is not in the cart leaves the cart unchanged.
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
  Applies a discount code typed by a customer, replacing any code already applied.

  Codes ignore case and surrounding whitespace. Unknown codes return an error
  and leave the cart's current code in place.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, {:unknown_code, String.t()}}
  def apply_discount_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_discount_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
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

  `prices` maps each SKU in the cart to its unit price in cents. The total is
  the item subtotal less any discount, plus the shipping fee. A SKU missing
  from `prices` raises `KeyError`.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    subtotal = subtotal_cents(cart, prices)

    discounted_subtotal(subtotal, cart.discount) + shipping_cents(cart.discount)
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)
  end

  # The discount rounds down to the cent, so the customer never gets more than 10% off.
  defp discounted_subtotal(subtotal, :save10), do: subtotal - div(subtotal * 10, 100)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping_cents(:free_shipping), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents

  defp parse_discount_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :free_shipping}
      _normalized -> {:error, {:unknown_code, code}}
    end
  end
end

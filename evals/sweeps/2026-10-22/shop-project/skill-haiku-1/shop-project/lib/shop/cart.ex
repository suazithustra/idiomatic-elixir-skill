defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

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

  Removing at least as many units as the cart holds removes the item. A SKU
  that is not in the cart leaves the cart unchanged.
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

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Applies a discount code, replacing any code already in the cart.

  Codes ignore case and surrounding spaces. `"SAVE10"` takes 10% off the item
  subtotal. `"FREESHIP"` waives the shipping fee. Returns
  `{:error, :unknown_code}` for any other code.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the amount to pay in cents: the item subtotal after the discount,
  plus the shipping fee.

  `price_list` maps each SKU to its unit price in cents. Returns
  `{:error, {:unknown_sku, sku}}` when the cart holds a SKU the price list
  does not contain.

  ## Examples

      iex> cart = Shop.Cart.new() |> Shop.Cart.add_item("APPLE", 2)
      iex> Shop.Cart.total_cents(cart, %{"APPLE" => 100})
      {:ok, 699}
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_cents(%__MODULE__{} = cart, price_list) do
    case subtotal_cents(cart, price_list) do
      {:ok, subtotal} ->
        {:ok, discounted_cents(subtotal, cart.discount) + shipping_cents(cart.discount)}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _other -> {:error, :unknown_code}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, price_list) do
    case Enum.find(items, fn {sku, _quantity} -> not Map.has_key?(price_list, sku) end) do
      nil ->
        {:ok,
         Enum.sum_by(items, fn {sku, quantity} -> quantity * Map.fetch!(price_list, sku) end)}

      {sku, _quantity} ->
        {:error, {:unknown_sku, sku}}
    end
  end

  defp discounted_cents(subtotal, :save10), do: subtotal - div(subtotal * 10 + 50, 100)
  defp discounted_cents(subtotal, _discount), do: subtotal

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents
end

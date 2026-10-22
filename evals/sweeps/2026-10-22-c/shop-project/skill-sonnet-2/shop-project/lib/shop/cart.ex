defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee 499

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

  Removing at least as many units as the cart holds removes the item.
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
  Applies a discount code, as typed by a customer, to the cart.

  "SAVE10" takes 10% off the item subtotal and "FREESHIP" waives the shipping
  fee. A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10

      iex> Shop.Cart.apply_code(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_code, "BOGUS"}}

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> Shop.Cart.apply_code(cart, "FREESHIP")
      {:error, {:code_already_applied, :save10}}
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_code, String.t()} | {:code_already_applied, discount()}}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      {:error, _reason} = error -> error
    end
  end

  def apply_code(%__MODULE__{discount: applied}, code) when is_binary(code) do
    {:error, {:code_already_applied, applied}}
  end

  @doc """
  Computes the total price in cents, given a map of SKU to unit price in cents.

  Every order pays a shipping fee of #{@shipping_fee} cents unless "FREESHIP"
  is applied. Returns an error for the first SKU in the cart that has no price.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 100})
      {:ok, 699}
  """
  @spec total(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    case subtotal(cart, prices) do
      {:ok, subtotal} -> {:ok, discounted(subtotal, cart.discount) + shipping(cart.discount)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_code(other), do: {:error, {:unknown_code, other}}

  defp subtotal(%__MODULE__{items: items}, prices) do
    case Enum.reject(Map.keys(items), &is_map_key(prices, &1)) do
      [] -> {:ok, Enum.sum_by(items, fn {sku, quantity} -> prices[sku] * quantity end)}
      [sku | _rest] -> {:error, {:unknown_sku, sku}}
    end
  end

  defp discounted(subtotal, :save10), do: subtotal - div(subtotal * 10, 100)
  defp discounted(subtotal, _discount), do: subtotal

  defp shipping(:free_shipping), do: 0
  defp shipping(_discount), do: @shipping_fee
end

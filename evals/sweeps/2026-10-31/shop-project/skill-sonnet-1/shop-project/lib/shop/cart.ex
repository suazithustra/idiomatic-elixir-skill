defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @enforce_keys [:items]
  defstruct [:items, :discount]

  @shipping_fee 499

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type prices :: %{sku() => non_neg_integer()}
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

  Removing as many units as the cart holds, or more, removes the item.
  A SKU that is not in the cart leaves the cart unchanged.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 3)
      iex> Shop.Cart.remove_item(cart, "APPLE", 1).items
      %{"APPLE" => 2}
      iex> Shop.Cart.remove_item(cart, "APPLE", 5).items
      %{}
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
  Applies a discount code, as typed by a customer, to the cart.

  Accepts "SAVE10" (10% off the item subtotal) and "FREESHIP" (no shipping fee).
  A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_discount(Shop.Cart.new(), "SAVE10")
      iex> cart.discount
      :save10
      iex> Shop.Cart.apply_discount(Shop.Cart.new(), "BOGUS")
      {:error, {:unknown_discount, "BOGUS"}}
      iex> Shop.Cart.apply_discount(cart, "FREESHIP")
      {:error, :discount_already_applied}
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, {:unknown_discount, String.t()} | :discount_already_applied}
  def apply_discount(%__MODULE__{} = cart, code) when is_binary(code) do
    with {:ok, discount} <- parse_discount(code),
         :ok <- ensure_no_discount(cart) do
      {:ok, %{cart | discount: discount}}
    end
  end

  @doc """
  Returns the total price in cents, given a map of SKU to price in cents.

  The total is the item subtotal, less any percentage discount, plus the
  shipping fee of #{@shipping_fee} cents unless "FREESHIP" is applied.

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, %{"APPLE" => 300})
      {:ok, 1099}
      iex> Shop.Cart.total(cart, %{})
      {:error, {:unknown_sku, "APPLE"}}
  """
  @spec total(t(), prices()) :: {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal(cart.items, prices) do
      {:ok, apply_percentage(subtotal, cart.discount) + shipping_fee(cart.discount)}
    end
  end

  defp remove_units(items, sku, quantity) do
    case Map.fetch(items, sku) do
      {:ok, held} when held > quantity -> Map.put(items, sku, held - quantity)
      {:ok, _held} -> Map.delete(items, sku)
      :error -> items
    end
  end

  defp parse_discount("SAVE10"), do: {:ok, :save10}
  defp parse_discount("FREESHIP"), do: {:ok, :freeship}
  defp parse_discount(code), do: {:error, {:unknown_discount, code}}

  defp ensure_no_discount(%__MODULE__{discount: nil}), do: :ok
  defp ensure_no_discount(%__MODULE__{}), do: {:error, :discount_already_applied}

  defp subtotal(items, prices) do
    case Enum.reject(Map.keys(items), &is_map_key(prices, &1)) do
      [] ->
        {:ok, Enum.sum_by(items, fn {sku, quantity} -> Map.fetch!(prices, sku) * quantity end)}

      [sku | _] ->
        {:error, {:unknown_sku, sku}}
    end
  end

  # Rounds to the nearest cent, halves up.
  defp apply_percentage(subtotal, :save10), do: div(subtotal * 90 + 50, 100)
  defp apply_percentage(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

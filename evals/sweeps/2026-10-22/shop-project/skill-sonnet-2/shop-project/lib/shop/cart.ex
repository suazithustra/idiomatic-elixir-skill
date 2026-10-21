defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, code: nil]

  @shipping_fee 499
  @save10_percent 10

  @type sku :: String.t()
  @type code :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: code() | nil}

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

  ## Examples

      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 3)
      iex> Shop.Cart.remove_item(cart, "APPLE", 2).items
      %{"APPLE" => 1}
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
  Applies a discount code, given as the string a customer typed.

  Known codes are `"SAVE10"` (10% off the item subtotal) and `"FREESHIP"`
  (no shipping fee). A cart holds at most one code.

  ## Examples

      iex> {:ok, cart} = Shop.Cart.apply_code(Shop.Cart.new(), "SAVE10")
      iex> cart.code
      :save10
      iex> Shop.Cart.apply_code(cart, "FREESHIP")
      {:error, :code_already_applied}
      iex> Shop.Cart.apply_code(Shop.Cart.new(), "BOGUS")
      {:error, :unknown_code}
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{} = cart, code) when is_binary(code) do
    with {:ok, parsed} <- parse_code(code),
         :ok <- ensure_no_code(cart) do
      {:ok, %{cart | code: parsed}}
    end
  end

  @doc """
  Returns the total price in cents, including shipping.

  `prices` maps each SKU to its price in cents. `"SAVE10"` is rounded to the
  nearest cent, halves up. Returns an error for a SKU missing from `prices`.

  ## Examples

      iex> prices = %{"APPLE" => 100, "PEAR" => 250}
      iex> cart = Shop.Cart.add_item(Shop.Cart.new(), "APPLE", 2)
      iex> Shop.Cart.total(cart, prices)
      {:ok, 699}
      iex> Shop.Cart.total(Shop.Cart.add_item(cart, "KIWI", 1), prices)
      {:error, {:unknown_sku, "KIWI"}}
  """
  @spec total(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    case subtotal(cart, prices) do
      {:ok, subtotal} -> {:ok, discounted(subtotal, cart.code) + shipping_fee(cart.code)}
      {:error, _reason} = error -> error
    end
  end

  defp remove_units(items, sku, quantity) do
    case items do
      %{^sku => held} when held > quantity -> Map.put(items, sku, held - quantity)
      %{^sku => _held} -> Map.delete(items, sku)
      %{} -> items
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_other), do: {:error, :unknown_code}

  defp ensure_no_code(%__MODULE__{code: nil}), do: :ok
  defp ensure_no_code(%__MODULE__{}), do: {:error, :code_already_applied}

  defp subtotal(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case Map.fetch(prices, sku) do
        {:ok, price} -> {:cont, {:ok, sum + price * quantity}}
        :error -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp discounted(subtotal, :save10) do
    subtotal - div(subtotal * @save10_percent + 50, 100)
  end

  defp discounted(subtotal, _code), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_code), do: @shipping_fee
end

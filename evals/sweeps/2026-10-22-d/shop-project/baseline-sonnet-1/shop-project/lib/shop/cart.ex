defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @shipping_fee 499

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

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Removes `quantity` units of `sku` from the cart.

  Removing at least as many units as the cart holds removes the item entirely.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case cart.items do
      %{^sku => held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      %{^sku => _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      _ ->
        cart
    end
  end

  @doc """
  Applies a discount code, as typed by a customer, to the cart.

  A cart holds at most one code, so applying a second one is an error.
  """
  @spec apply_discount(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :already_applied}
  def apply_discount(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      :error -> {:error, :unknown_code}
    end
  end

  def apply_discount(%__MODULE__{}, code) when is_binary(code), do: {:error, :already_applied}

  @doc """
  Computes the total in cents, given a `prices` map of SKU to price in cents.

  Raises `KeyError` if the cart holds a SKU missing from `prices`.
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_price(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal =
      Enum.reduce(cart.items, 0, fn {sku, quantity}, acc ->
        acc + Map.fetch!(prices, sku) * quantity
      end)

    discounted_subtotal(subtotal, cart.discount) + shipping_fee(cart.discount)
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_code), do: :error

  defp discounted_subtotal(subtotal, :save10), do: subtotal - div(subtotal * 10, 100)
  defp discounted_subtotal(subtotal, _discount), do: subtotal

  defp shipping_fee(:freeship), do: 0
  defp shipping_fee(_discount), do: @shipping_fee
end

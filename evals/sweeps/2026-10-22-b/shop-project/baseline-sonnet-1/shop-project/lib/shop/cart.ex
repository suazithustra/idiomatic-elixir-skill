defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

  @shipping_fee 499

  @type sku :: String.t()
  @type discount :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount: discount() | nil}
  @type prices :: %{sku() => non_neg_integer()}

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
  Removing an item that is not in the cart leaves the cart unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{items: items} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case items do
      %{^sku => held} when held > quantity -> %{cart | items: %{items | sku => held - quantity}}
      %{^sku => _} -> %{cart | items: Map.delete(items, sku)}
      %{} -> cart
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

  Surrounding whitespace is ignored. A cart holds at most one code.
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_code(String.trim(code)) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      :error -> {:error, :unknown_code}
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  @doc """
  Computes the total price in cents, given a map of SKU to unit price in cents.

  "SAVE10" takes 10% off the item subtotal (the discount is rounded down).
  Shipping is 499 cents unless "FREESHIP" is applied. Returns an error if a
  SKU in the cart has no price.
  """
  @spec total(t(), prices()) :: {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total(%__MODULE__{items: items, discount: discount}, prices) do
    with {:ok, subtotal} <- subtotal(items, prices) do
      {:ok, discounted(subtotal, discount) + shipping(discount)}
    end
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_), do: :error

  defp subtotal(items, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, acc} ->
      case prices do
        %{^sku => price} -> {:cont, {:ok, acc + price * quantity}}
        %{} -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp discounted(subtotal, :save10), do: subtotal - div(subtotal * 10, 100)
  defp discounted(subtotal, _), do: subtotal

  defp shipping(:freeship), do: 0
  defp shipping(_), do: @shipping_fee
end

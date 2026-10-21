defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct items: %{}, discount: nil

  @type sku :: String.t()
  @type discount :: :save10 | :free_shipping
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
      %{^sku => _held} -> %{cart | items: Map.delete(items, sku)}
      %{} -> cart
    end
  end

  @doc """
  Applies a discount code, as typed by a customer, to the cart.

  Supported codes are `"SAVE10"` and `"FREESHIP"`. A cart holds at most one
  code, so applying a second code returns `{:error, :code_already_applied}`.
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{discount: nil} = cart, code) when is_binary(code) do
    case parse_code(code) do
      {:ok, discount} -> {:ok, %{cart | discount: discount}}
      :error -> {:error, :unknown_code}
    end
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  @doc """
  Returns the total price in cents: item subtotal, minus any discount, plus shipping.

  Shipping is 499 cents unless `"FREESHIP"` is applied. `"SAVE10"` takes 10% off the
  item subtotal, rounded to the nearest cent (halves round up). Returns
  `{:error, {:unknown_sku, sku}}` if the price list lacks a SKU in the cart.
  """
  @spec total_cents(t(), prices()) :: {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_cents(%__MODULE__{items: items, discount: discount}, prices) do
    with {:ok, subtotal} <- subtotal_cents(items, prices) do
      {:ok, discounted(subtotal, discount) + shipping(discount)}
    end
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :free_shipping}
  defp parse_code(_other), do: :error

  defp subtotal_cents(items, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, sum} ->
      case prices do
        %{^sku => price} -> {:cont, {:ok, sum + price * quantity}}
        %{} -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp discounted(subtotal, :save10), do: subtotal - div(subtotal + 5, 10)
  defp discounted(subtotal, _discount), do: subtotal

  defp shipping(:free_shipping), do: 0
  defp shipping(_discount), do: @shipping_fee
end

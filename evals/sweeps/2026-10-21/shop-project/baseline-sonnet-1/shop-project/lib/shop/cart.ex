defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, discount: nil]

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
    case cart.items do
      %{^sku => held} when held > quantity ->
        %{cart | items: Map.put(cart.items, sku, held - quantity)}

      %{^sku => _held} ->
        %{cart | items: Map.delete(cart.items, sku)}

      _ ->
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
  Applies a discount code typed by a customer.

  Codes are matched ignoring case and surrounding whitespace. A cart holds at
  most one code, so applying a second one is an error.
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
  Computes the total in cents, given a map of SKU to unit price in cents.

  Returns an error if the cart holds a SKU missing from `prices`.
  "SAVE10" takes 10% off the item subtotal (rounded to the nearest cent);
  the shipping fee is 499 cents unless "FREESHIP" is applied.
  """
  @spec total_cents(t(), %{sku() => non_neg_integer()}) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_sku, sku()}}
  def total_cents(%__MODULE__{} = cart, prices) when is_map(prices) do
    with {:ok, subtotal} <- subtotal_cents(cart, prices) do
      {:ok, subtotal - discount_cents(cart.discount, subtotal) + shipping_cents(cart.discount)}
    end
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.reduce_while(items, {:ok, 0}, fn {sku, quantity}, {:ok, acc} ->
      case prices do
        %{^sku => price} -> {:cont, {:ok, acc + price * quantity}}
        _ -> {:halt, {:error, {:unknown_sku, sku}}}
      end
    end)
  end

  defp discount_cents(:save10, subtotal), do: div(subtotal + 5, 10)
  defp discount_cents(_discount, _subtotal), do: 0

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_discount), do: @shipping_fee_cents

  defp parse_code(code) do
    case code |> String.trim() |> String.upcase() do
      "SAVE10" -> {:ok, :save10}
      "FREESHIP" -> {:ok, :freeship}
      _ -> :error
    end
  end
end

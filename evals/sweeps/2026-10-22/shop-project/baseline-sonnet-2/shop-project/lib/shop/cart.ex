defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @enforce_keys [:items]
  defstruct [:items, code: nil]

  @shipping_fee 499

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

  @doc """
  Applies a discount code, given as the string a customer typed.

  Supported codes are "SAVE10" and "FREESHIP". A cart holds at most one
  code, so applying a valid code replaces any earlier one. Unknown codes
  are rejected and leave the cart unchanged.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, "SAVE10"), do: {:ok, %{cart | code: :save10}}
  def apply_code(%__MODULE__{} = cart, "FREESHIP"), do: {:ok, %{cart | code: :freeship}}
  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :unknown_code}

  @doc """
  Computes the total price in cents, including shipping.

  `prices` maps each SKU to its price in cents. Raises `KeyError` if the
  cart holds a SKU missing from `prices`. "SAVE10" takes 10% off the item
  subtotal, rounded down to a whole cent. "FREESHIP" waives the shipping fee.
  """
  @spec total(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) when is_map(prices) do
    subtotal =
      Enum.reduce(cart.items, 0, fn {sku, quantity}, acc ->
        acc + Map.fetch!(prices, sku) * quantity
      end)

    discounted =
      case cart.code do
        :save10 -> subtotal - div(subtotal * 10, 100)
        _ -> subtotal
      end

    shipping =
      case cart.code do
        :freeship -> 0
        _ -> @shipping_fee
      end

    discounted + shipping
  end

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end
end

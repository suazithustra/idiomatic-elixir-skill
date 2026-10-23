defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @shipping_fee 499

  @enforce_keys [:items]
  defstruct [:items, code: nil]

  @type sku :: String.t()
  @type code :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, code: code() | nil}

  @doc "Returns an empty cart."
  @spec new() :: t()
  def new, do: %__MODULE__{items: %{}}

  @doc """
  Removes `quantity` units of `sku` from the cart.

  Removing at least as many units as the cart holds removes the item entirely.
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
  code, so applying a second one is an error.
  """
  @spec apply_code(t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_code | :code_already_applied}
  def apply_code(%__MODULE__{code: nil} = cart, code) when is_binary(code) do
    with {:ok, parsed} <- parse_code(code), do: {:ok, %{cart | code: parsed}}
  end

  def apply_code(%__MODULE__{}, code) when is_binary(code), do: {:error, :code_already_applied}

  defp parse_code("SAVE10"), do: {:ok, :save10}
  defp parse_code("FREESHIP"), do: {:ok, :freeship}
  defp parse_code(_unknown), do: {:error, :unknown_code}

  @doc """
  Computes the total price in cents.

  `prices` maps each SKU to its unit price in cents; a SKU missing from it
  raises `KeyError`. Shipping is 499 cents unless `"FREESHIP"` is applied.
  """
  @spec total_price(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total_price(%__MODULE__{items: items, code: code}, prices) do
    subtotal =
      Enum.reduce(items, 0, fn {sku, quantity}, acc ->
        acc + Map.fetch!(prices, sku) * quantity
      end)

    discounted = if code == :save10, do: subtotal - div(subtotal * 10 + 50, 100), else: subtotal
    shipping = if code == :freeship, do: 0, else: @shipping_fee

    discounted + shipping
  end

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
end

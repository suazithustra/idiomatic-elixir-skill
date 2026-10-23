defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU.
  """

  @shipping_fee 499

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
    items =
      case cart.items do
        %{^sku => held} when held > quantity -> %{cart.items | sku => held - quantity}
        items -> Map.delete(items, sku)
      end

    %{cart | items: items}
  end

  @doc """
  Applies a discount code to the cart, replacing any code already applied.

  Known codes are `"SAVE10"` and `"FREESHIP"`; anything else is rejected.
  """
  @spec apply_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_code(%__MODULE__{} = cart, "SAVE10"), do: {:ok, %{cart | discount: :save10}}
  def apply_code(%__MODULE__{} = cart, "FREESHIP"), do: {:ok, %{cart | discount: :freeship}}
  def apply_code(%__MODULE__{}, _code), do: {:error, :unknown_code}

  @doc """
  Computes the total in cents, using `prices` (a map of SKU to price in cents).

  Includes the shipping fee unless `"FREESHIP"` is applied. Raises `KeyError`
  if the cart holds a SKU missing from `prices`.
  """
  @spec total(t(), %{sku() => non_neg_integer()}) :: non_neg_integer()
  def total(%__MODULE__{} = cart, prices) do
    subtotal =
      Enum.reduce(cart.items, 0, fn {sku, quantity}, acc ->
        acc + Map.fetch!(prices, sku) * quantity
      end)

    case cart.discount do
      :save10 -> subtotal - div(subtotal * 10, 100) + @shipping_fee
      :freeship -> subtotal
      nil -> subtotal + @shipping_fee
    end
  end
end

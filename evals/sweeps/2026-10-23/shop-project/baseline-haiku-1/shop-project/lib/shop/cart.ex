defmodule Shop.Cart do
  @moduledoc """
  A shopping cart that holds a quantity per SKU and at most one discount code.
  """

  @shipping_fee_cents 499

  @enforce_keys [:items]
  defstruct [:items, discount_code: nil]

  @type sku :: String.t()
  @type code :: :save10 | :freeship
  @type t :: %__MODULE__{items: %{sku() => pos_integer()}, discount_code: code() | nil}
  @type price_list :: %{sku() => non_neg_integer()}

  @codes %{"SAVE10" => :save10, "FREESHIP" => :freeship}

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
  Removes `quantity` units of `sku` from the cart. Removing at least as many
  units as the cart holds removes the item entirely. If `sku` is not in the
  cart, the cart is returned unchanged.
  """
  @spec remove_item(t(), sku(), pos_integer()) :: t()
  def remove_item(%__MODULE__{} = cart, sku, quantity)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    case Map.fetch(cart.items, sku) do
      :error ->
        cart

      {:ok, current} when quantity >= current ->
        %{cart | items: Map.delete(cart.items, sku)}

      {:ok, current} ->
        %{cart | items: Map.put(cart.items, sku, current - quantity)}
    end
  end

  @doc """
  Applies a discount code typed by a customer. The input is trimmed and matched
  case-insensitively. A cart holds at most one code, so applying a second code
  replaces the first. Unknown codes return `{:error, :unknown_code}`.
  """
  @spec apply_discount_code(t(), String.t()) :: {:ok, t()} | {:error, :unknown_code}
  def apply_discount_code(%__MODULE__{} = cart, input) when is_binary(input) do
    case Map.fetch(@codes, input |> String.trim() |> String.upcase()) do
      {:ok, code} -> {:ok, %{cart | discount_code: code}}
      :error -> {:error, :unknown_code}
    end
  end

  def apply_discount_code(%__MODULE__{}, _input), do: {:error, :unknown_code}

  @doc "Returns the total number of units in the cart."
  @spec total_quantity(t()) :: non_neg_integer()
  def total_quantity(%__MODULE__{items: items}) do
    items
    |> Map.values()
    |> Enum.sum()
  end

  @doc """
  Returns the amount to pay in cents: the item subtotal after any discount,
  plus the shipping fee. The discount is rounded down to the nearest cent.
  Raises `KeyError` if a SKU in the cart is missing from `prices`.
  """
  @spec total_cents(t(), price_list()) :: non_neg_integer()
  def total_cents(%__MODULE__{} = cart, prices) do
    cart
    |> subtotal_cents(prices)
    |> discounted_cents(cart.discount_code)
    |> Kernel.+(shipping_cents(cart.discount_code))
  end

  defp subtotal_cents(%__MODULE__{items: items}, prices) do
    Enum.reduce(items, 0, fn {sku, quantity}, acc ->
      acc + quantity * Map.fetch!(prices, sku)
    end)
  end

  defp discounted_cents(subtotal, :save10), do: subtotal - div(subtotal * 10, 100)
  defp discounted_cents(subtotal, _code), do: subtotal

  defp shipping_cents(:freeship), do: 0
  defp shipping_cents(_code), do: @shipping_fee_cents
end

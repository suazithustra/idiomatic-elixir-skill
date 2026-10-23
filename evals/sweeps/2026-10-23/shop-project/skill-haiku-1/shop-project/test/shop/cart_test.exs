defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Cart

  describe "add_item/3" do
    test "adds a new item" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert cart.items == %{"APPLE" => 2}
    end

    test "increases the quantity of an item already in the cart" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("APPLE", 3)

      assert cart.items == %{"APPLE" => 5}
    end
  end

  describe "remove_item/3" do
    test "lowers the quantity of an item by the units removed" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when all of its units are removed" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when more units are removed than the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged when the SKU is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "stores a known code" do
      assert {:ok, %Cart{code: "SAVE10"}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "accepts a code with different case and surrounding spaces" do
      assert {:ok, %Cart{code: "FREESHIP"}} = Cart.apply_code(Cart.new(), " freeship ")
    end

    test "replaces the code already in the cart" do
      assert {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{code: "FREESHIP"}} = Cart.apply_code(cart, "FREESHIP")
    end

    test "returns an error and keeps the cart unchanged for an unknown code" do
      cart = Cart.new()

      assert Cart.apply_code(cart, "BOGUS") == {:error, :unknown_code}
    end
  end

  describe "total_cents/2" do
    setup do
      prices = %{"APPLE" => 150, "PEAR" => 99}
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: prices}
    end

    test "adds shipping to the subtotal when there is no code", %{cart: cart, prices: prices} do
      assert Cart.total_cents(cart, prices) == 399 + 499
    end

    test "takes 10% off the subtotal with SAVE10 and keeps the shipping fee", %{
      cart: cart,
      prices: prices
    } do
      assert {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      assert Cart.total_cents(cart, prices) == 359 + 499
    end

    test "rounds the discounted subtotal to the nearest cent, halves up", %{prices: prices} do
      cart = Cart.add_item(Cart.new(), "APPLE", 1)
      assert {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      assert Cart.total_cents(cart, %{prices | "APPLE" => 1005}) == 905 + 499
    end

    test "waives the shipping fee with FREESHIP and keeps the full subtotal", %{
      cart: cart,
      prices: prices
    } do
      assert {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert Cart.total_cents(cart, prices) == 399
    end

    test "raises when a SKU in the cart has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_cents(cart, %{"APPLE" => 150}) end
    end
  end

  describe "total_quantity/1" do
    test "sums the units of every item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_quantity(cart) == 3
    end
  end
end

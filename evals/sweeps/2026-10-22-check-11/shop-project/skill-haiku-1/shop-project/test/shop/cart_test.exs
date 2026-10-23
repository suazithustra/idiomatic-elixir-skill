defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

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

  describe "total_quantity/1" do
    test "sums the units of every item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_quantity(cart) == 3
    end
  end

  describe "remove_item/3" do
    test "removes some units and keeps the rest" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 3)
        |> Cart.remove_item("APPLE", 1)

      assert cart.items == %{"APPLE" => 2}
    end

    test "removes the item when the quantity equals the units it holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when more units are removed than it holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 5)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for an item it does not hold" do
      cart =
        Cart.new()
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 1)

      assert cart.items == %{"PEAR" => 1}
    end
  end

  describe "apply_discount_code/2" do
    test "accepts a code regardless of case and surrounding spaces" do
      assert {:ok, %Cart{discount: :save10}} =
               Cart.apply_discount_code(Cart.new(), " save10 ")
    end

    test "replaces the code already in the cart" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert {:error, {:unknown_code, "BOGUS"}} = Cart.apply_discount_code(Cart.new(), "bogus")
    end
  end

  describe "total_cents/2" do
    test "sums the price of every unit and adds shipping" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, %{"APPLE" => 150, "PEAR" => 200}) == 999
    end

    test "takes 10% off the item subtotal, rounding halves up" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 1)
               |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, %{"APPLE" => 1005}) == 904 + 499
    end

    test "charges shipping with SAVE10 applied" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.add_item("PEAR", 1)
               |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, %{"APPLE" => 150, "PEAR" => 200}) == 450 + 499
    end

    test "waives shipping with FREESHIP applied" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.add_item("PEAR", 1)
               |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, %{"APPLE" => 150, "PEAR" => 200}) == 500
    end

    test "raises when the price list has no price for an item in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, %{}) end
    end
  end
end

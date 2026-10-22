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

  describe "remove_item/3" do
    test "removes some units and keeps the rest" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the quantity removes every unit" do
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
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{}
    end

    test "leaves the other items alone" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"PEAR" => 1}
    end
  end

  describe "apply_discount/2" do
    test "accepts SAVE10 in any letter case and with surrounding whitespace" do
      assert {:ok, %Cart{discount: "SAVE10"}} = Cart.apply_discount(Cart.new(), " save10 ")
    end

    test "accepts FREESHIP" do
      assert {:ok, %Cart{discount: "FREESHIP"}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "replaces the code already applied" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: "FREESHIP"}} = Cart.apply_discount(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert {:error, {:unknown_code, "BOGUS"}} = Cart.apply_discount(Cart.new(), "BOGUS")
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 300}

    test "adds shipping to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 600 + 499
    end

    test "charges shipping for an empty cart" do
      assert Cart.total_cents(Cart.new(), @prices) == 499
    end

    test "takes 10% off the item subtotal with SAVE10" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      assert Cart.total_cents(cart, @prices) == 540 + 499
    end

    test "rounds the SAVE10 discount half up to the nearest cent" do
      cart = Cart.add_item(Cart.new(), "PEN", 1)

      assert {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      # 10% of 105 is 10.5, which rounds to 11
      assert Cart.total_cents(cart, %{"PEN" => 105}) == 94 + 499
    end

    test "waives shipping with FREESHIP" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total_cents(cart, @prices) == 300
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

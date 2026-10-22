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
    test "removes some units of an item, keeping the rest" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the quantity equals what the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when the quantity is more than the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for a SKU it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts SAVE10 and stores it in the cart" do
      assert {:ok, %Cart{discount_code: "SAVE10"}} =
               Cart.apply_discount_code(Cart.new(), "SAVE10")
    end

    test "accepts FREESHIP and stores it in the cart" do
      assert {:ok, %Cart{discount_code: "FREESHIP"}} =
               Cart.apply_discount_code(Cart.new(), "FREESHIP")
    end

    test "replaces the code already in the cart with the new one" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount_code: "FREESHIP"}} = Cart.apply_discount_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "SAVE50") ==
               {:error, {:unknown_code, "SAVE50"}}
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

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 200}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 500 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, not off the shipping fee" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "rounds the SAVE10 discount to the nearest cent, halves up" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, %{"APPLE" => 155}) == 155 - 16 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "charges only the shipping fee for an empty cart with no code" do
      assert Cart.total_cents(Cart.new(), @prices) == 499
    end

    test "raises when the price list has no price for a SKU in the cart" do
      cart = Cart.add_item(Cart.new(), "KIWI", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end
end

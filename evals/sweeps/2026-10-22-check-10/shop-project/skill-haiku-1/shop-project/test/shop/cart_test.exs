defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Cart

  @prices %{"APPLE" => 150, "PEAR" => 200}

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

    test "removes the item when the quantity exceeds the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged when the item is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "applies a known code, ignoring surrounding space and case" do
      assert {:ok, %Cart{code: "SAVE10"}} = Cart.apply_discount_code(Cart.new(), " save10 ")
    end

    test "replaces the code already applied" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{code: "FREESHIP"}} = Cart.apply_discount_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert {:error, :unknown_code} = Cart.apply_discount_code(Cart.new(), "NOPE")
    end
  end

  describe "total_cents/2" do
    test "sums the prices of every item and adds the shipping fee" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 300 + 200 + 499
    end

    test "takes 10% off the item subtotal with SAVE10" do
      cart = Cart.add_item(Cart.new(), "APPLE", 1)
      assert {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")

      # 150 - 15 = 135, plus shipping
      assert Cart.total_cents(cart, @prices) == 135 + 499
    end

    test "rounds the SAVE10 discount half up to the nearest cent" do
      cart = Cart.add_item(Cart.new(), "APPLE", 5)
      assert {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")

      # 10% of 75 cents is 7.5 cents, which rounds up to 8: 75 - 8 = 67, plus shipping
      assert Cart.total_cents(cart, %{"APPLE" => 15}) == 67 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      cart = Cart.add_item(Cart.new(), "APPLE", 1)
      assert {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert Cart.total_cents(cart, @prices) == 150
    end

    test "raises when the price list does not cover an item in the cart" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
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

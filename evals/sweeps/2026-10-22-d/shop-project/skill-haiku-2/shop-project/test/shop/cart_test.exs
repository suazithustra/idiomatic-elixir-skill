defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  @prices %{"APPLE" => 100, "PEAR" => 250}

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

    test "removes the item when the quantity equals the units held" do
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
        |> Cart.remove_item("APPLE", 5)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for an item it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "applies a known code" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert cart.discount_code == :save10
    end

    test "replaces the code already applied" do
      assert {:ok, with_save10} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert {:ok, cart} = Cart.apply_discount_code(with_save10, "FREESHIP")

      assert cart.discount_code == :freeship
    end

    test "returns an error for an unknown code" do
      assert {:error, {:unknown_code, "BOGUS"}} =
               Cart.apply_discount_code(Cart.new(), "BOGUS")
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
    test "adds the shipping fee to the item prices" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 200 + 250 + 499
    end

    test "takes 10% off the item subtotal with SAVE10 and keeps the shipping fee" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 180 + 499
    end

    test "rounds the SAVE10 discount to the nearest cent, halves up" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 1)
               |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, %{"APPLE" => 5}) == 4 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      assert {:ok, cart} =
               Cart.new()
               |> Cart.add_item("APPLE", 2)
               |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 200
    end

    test "raises when the cart holds a SKU without a price" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @prices) end
    end
  end
end

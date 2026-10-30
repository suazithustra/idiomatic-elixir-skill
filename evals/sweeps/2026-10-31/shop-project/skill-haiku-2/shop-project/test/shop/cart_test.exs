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

    test "removes the item when the quantity equals what the cart holds" do
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

    test "leaves the cart unchanged for a SKU not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts SAVE10 and FREESHIP, ignoring case and surrounding spaces" do
      assert {:ok, %Cart{discount_code: :save10}} =
               Cart.apply_discount_code(Cart.new(), " save10 ")

      assert {:ok, %Cart{discount_code: :free_shipping}} =
               Cart.apply_discount_code(Cart.new(), "FreeShip")
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "NOPE") ==
               {:error, {:unknown_code, "NOPE"}}
    end

    test "a second code replaces the first" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount_code == :free_shipping
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 300}

    test "adds the shipping fee when there is no discount" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 600 + 499
    end

    test "SAVE10 takes 10% off the item subtotal" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 270 + 499
    end

    test "SAVE10 rounds the discount to the nearest cent" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_discount_code("SAVE10")

      # 10% of 155 is 15.5 cents, which rounds to 16 off
      assert Cart.total_cents(cart, %{"APPLE" => 155}) == 139 + 499
    end

    test "FREESHIP waives the shipping fee" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

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

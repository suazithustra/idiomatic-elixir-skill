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
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the quantity removed equals the quantity held" do
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
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for an item it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts SAVE10 regardless of case and surrounding whitespace" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount_code(Cart.new(), " save10 ")
    end

    test "accepts FREESHIP regardless of case" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "FreeShip")
      assert cart.discount == :free_shipping
    end

    test "replaces the code the cart already holds" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_discount_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "HALFOFF") ==
               {:error, {:unknown_code, "HALFOFF"}}
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 200}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 300 + 200 + 499
    end

    test "takes 10% off the item subtotal, not the shipping fee" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 270 + 499
    end

    test "rounds the discount to the nearest cent, halves up" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, %{"APPLE" => 5}) == 4 + 499
    end

    test "waives the shipping fee for FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end
  end
end

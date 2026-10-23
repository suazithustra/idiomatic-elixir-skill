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

    test "removes the item when asked for as many units as it holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when asked for more units than it holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for an SKU it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
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

  describe "apply_discount_code/2" do
    test "stores a known code on the cart" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount_code(Cart.new(), "SAVE10")
    end

    test "matches the code without regard to case or surrounding spaces" do
      assert {:ok, %Cart{discount: :free_shipping}} =
               Cart.apply_discount_code(Cart.new(), "  freeship ")
    end

    test "replaces the code already in the cart" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_discount_code(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert {:error, {:unknown_code, "BOGUS"}} = Cart.apply_discount_code(Cart.new(), "BOGUS")
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 250, "PEAR" => 100, "CHEESE" => 1005}

    test "adds the shipping fee to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 600 + 499
    end

    test "takes 10% off the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")
      assert Cart.total_cents(cart, @prices) == 540 + 499
    end

    test "rounds the SAVE10 discount half up to the cent" do
      cart = Cart.add_item(Cart.new(), "CHEESE", 1)

      assert {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")
      assert Cart.total_cents(cart, @prices) == 904 + 499
    end

    test "waives the shipping fee for FREESHIP" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")
      assert Cart.total_cents(cart, @prices) == 500
    end

    test "charges shipping on an empty cart" do
      assert Cart.total_cents(Cart.new(), @prices) == 499
    end
  end
end

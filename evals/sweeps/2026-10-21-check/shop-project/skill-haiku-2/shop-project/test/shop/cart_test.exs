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

    test "removes the item when the quantity matches the units held" do
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

    test "leaves the cart unchanged for a SKU it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts SAVE10 and FREESHIP regardless of case and surrounding spaces" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), " save10 ")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FreeShip")
    end

    test "rejects an unknown code" do
      assert {:error, :unknown_code} = Cart.apply_discount(Cart.new(), "BOGUS")
    end

    test "replaces the code already applied" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(cart, "FREESHIP")
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 200, "MELON" => 155}

    test "adds the shipping fee when no code is applied" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 500 + 499
    end

    test "takes 10% off the item subtotal and keeps the shipping fee with SAVE10" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount("SAVE10")

      assert Cart.total_cents(cart, @prices) == 450 + 499
    end

    test "rounds the discount to the nearest cent, halves up" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("MELON", 1)
        |> Cart.apply_discount("SAVE10")

      assert Cart.total_cents(cart, @prices) == 139 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 500
    end

    test "raises when a SKU in the cart has no price" do
      cart = Cart.add_item(Cart.new(), "KIWI", 1)

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

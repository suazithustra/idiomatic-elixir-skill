defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  @price_list %{"APPLE" => 150, "PEAR" => 99, "ITEM" => 105}

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
    test "keeps the units that are not removed" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when the removed units are all of it" do
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

    test "leaves the cart unchanged for an SKU it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts a code typed with other case and surrounding spaces" do
      assert {:ok, %Cart{discount_code: :save10}} =
               Cart.apply_discount_code(Cart.new(), " save10 ")
    end

    test "replaces the code already in the cart" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount_code == :freeship
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "BOGUS") == {:error, :unknown_discount_code}
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
    test "sums the item prices and adds the shipping fee" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @price_list) == 898
    end

    test "takes 10% off the item subtotal for SAVE10, not off the shipping fee" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")

      assert Cart.total_cents(cart, @price_list) == 858
    end

    test "rounds the SAVE10 discount half up to the cent" do
      cart = Cart.add_item(Cart.new(), "ITEM", 1)

      assert {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")

      assert Cart.total_cents(cart, @price_list) == 593
    end

    test "waives the shipping fee for FREESHIP" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert Cart.total_cents(cart, @price_list) == 399
    end

    test "raises for an SKU missing from the price list" do
      cart = Cart.add_item(Cart.new(), "MANGO", 1)

      assert_raise KeyError, fn -> Cart.total_cents(cart, @price_list) end
    end
  end
end

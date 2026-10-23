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

    test "removes the item when removing exactly its quantity" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when removing more units than the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged when the sku is not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts a known code" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert cart.discount_code == :save10
    end

    test "ignores surrounding whitespace and letter case" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "  freeship ")
      assert cart.discount_code == :freeship
    end

    test "rejects an unknown code" do
      assert {:error, :unknown_code} = Cart.apply_discount_code(Cart.new(), "NOPE")
    end

    test "rejects a non-string input" do
      assert {:error, :unknown_code} = Cart.apply_discount_code(Cart.new(), nil)
    end

    test "replaces the code already in the cart" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount_code == :freeship
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 200, "PEAR" => 150}

    test "adds the shipping fee to the subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 550 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, not off shipping" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("SAVE10")

      assert Cart.total_cents(cart, @prices) == 360 + 499
    end

    test "waives the shipping fee with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 400
    end

    test "rounds the SAVE10 discount down to a whole cent" do
      prices = %{"CHEAP" => 105}

      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("CHEAP", 1)
        |> Cart.apply_discount_code("SAVE10")

      # discount is 10.5 cents, rounded down to 10, so the subtotal is 95
      assert Cart.total_cents(cart, prices) == 95 + 499
    end

    test "raises when a sku has no price" do
      cart = Cart.add_item(Cart.new(), "MISSING", 1)

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

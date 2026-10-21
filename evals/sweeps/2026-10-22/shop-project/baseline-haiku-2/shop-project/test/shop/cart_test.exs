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
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged when the sku is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts a known code, ignoring case and surrounding spaces" do
      assert {:ok, %Cart{discount_code: "SAVE10"}} =
               Cart.apply_discount_code(Cart.new(), "  save10 ")
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "NOPE") == {:error, :unknown_code}
    end

    test "replaces the code already on the cart" do
      {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")

      assert cart.discount_code == "FREESHIP"
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 200, "PEAR" => 150}

    test "adds shipping to the subtotal when there is no code" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 550 + 499
    end

    test "takes 10% off the item subtotal with SAVE10" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("SAVE10")

      # 400 - 40 = 360, plus 499 shipping
      assert Cart.total_cents(cart, @prices) == 360 + 499
    end

    test "rounds the SAVE10 discount half up to the cent" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("PEAR", 1)
        |> Cart.apply_discount_code("SAVE10")

      # 150 * 10% = 15 exactly; 155 * 10% = 15.5 rounds to 16
      assert Cart.total_cents(cart, %{"PEAR" => 155}) == 139 + 499
      assert Cart.total_cents(cart, @prices) == 135 + 499
    end

    test "waives shipping with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_discount_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 400
    end

    test "raises when a sku has no price" do
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

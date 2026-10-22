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

    test "removes the item when removing exactly what the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when removing more than the cart holds" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 9)

      assert cart.items == %{}
    end

    test "leaves the cart unchanged for a sku not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)

      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts a known code, ignoring case and surrounding whitespace" do
      assert {:ok, %Cart{discount_code: :save10}} = Cart.apply_code(Cart.new(), " save10 ")
      assert {:ok, %Cart{discount_code: :free_shipping}} = Cart.apply_code(Cart.new(), "FreeShip")
    end

    test "replaces the code already in the cart" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert cart.discount_code == :free_shipping
    end

    test "rejects an unknown code" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, {:unknown_code, "BOGUS"}}
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 150, "PEAR" => 200}

    test "adds shipping to the item subtotal" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      assert Cart.total_cents(cart, @prices) == 500 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, rounding half up" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_code("SAVE10")

      # 10% of 150 is 15, so 135 + 499 shipping
      assert Cart.total_cents(cart, @prices) == 135 + 499

      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("PEAR", 1)
        |> Cart.add_item("APPLE", 1)
        |> Cart.apply_code("SAVE10")

      # 10% of 350 is 35, so 315 + 499 shipping
      assert Cart.total_cents(cart, @prices) == 315 + 499
    end

    test "waives shipping with FREESHIP" do
      {:ok, cart} =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.apply_code("FREESHIP")

      assert Cart.total_cents(cart, @prices) == 300
    end

    test "raises for a sku missing from the price list" do
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

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
    test "removes some units of an item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when removing exactly the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when removing more units than held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged when the item is not in it" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
    end

    test "accepts FREESHIP" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "ignores surrounding whitespace and letter case" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "  save10 ")
    end

    test "rejects unknown codes" do
      assert Cart.apply_discount(Cart.new(), "SAVE50") == {:error, :unknown_code}
      assert Cart.apply_discount(Cart.new(), "") == {:error, :unknown_code}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
      assert Cart.apply_discount(cart, "SAVE10") == {:error, :discount_already_applied}
    end
  end

  describe "total_price/2" do
    @prices %{"APPLE" => 150, "PEAR" => 205}

    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 3)

      %{cart: cart}
    end

    test "adds shipping to the item subtotal", %{cart: cart} do
      assert Cart.total_price(cart, @prices) == 2 * 150 + 3 * 205 + 499
    end

    test "charges only shipping for an empty cart" do
      assert Cart.total_price(Cart.new(), @prices) == 499
    end

    test "SAVE10 takes 10% off the subtotal but not shipping", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")

      # Subtotal 915, discount 91 (rounded down from 91.5).
      assert Cart.total_price(cart, @prices) == 915 - 91 + 499
    end

    test "FREESHIP waives shipping", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total_price(cart, @prices) == 915
    end

    test "raises when a SKU has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_price(cart, %{"APPLE" => 150}) end
    end
  end
end

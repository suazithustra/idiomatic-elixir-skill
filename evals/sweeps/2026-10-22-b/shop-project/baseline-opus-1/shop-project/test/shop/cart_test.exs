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
      cart = Cart.new() |> Cart.add_item("APPLE", 5) |> Cart.remove_item("APPLE", 2)
      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when removing exactly the units held" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.remove_item("APPLE", 2)
      assert cart.items == %{}
    end

    test "removes the item when removing more units than held" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.remove_item("APPLE", 10)
      assert cart.items == %{}
    end

    test "leaves the cart unchanged for an item not in the cart" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts a known code" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount(Cart.new(), "BOGUS") == {:error, :unknown_code}
      assert Cart.apply_discount(Cart.new(), "save10") == {:error, :unknown_code}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
      assert Cart.apply_discount(cart, "SAVE10") == {:error, :discount_already_applied}
    end
  end

  describe "total/2" do
    @prices %{"APPLE" => 150, "PEAR" => 205}

    setup do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1)
      %{cart: cart}
    end

    test "adds shipping to the item subtotal", %{cart: cart} do
      assert Cart.total(cart, @prices) == 505 + 499
    end

    test "takes 10% off the subtotal with SAVE10", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      # 10% of 505 is 50.5, rounded to 51
      assert Cart.total(cart, @prices) == 505 - 51 + 499
    end

    test "waives shipping with FREESHIP", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total(cart, @prices) == 505
    end

    test "raises when a SKU has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total(cart, %{"APPLE" => 150}) end
    end
  end
end

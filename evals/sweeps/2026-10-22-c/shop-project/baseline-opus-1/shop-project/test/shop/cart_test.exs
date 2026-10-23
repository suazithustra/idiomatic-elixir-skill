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
    setup do
      %{cart: Cart.add_item(Cart.new(), "APPLE", 3)}
    end

    test "removes some units", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when removing exactly what the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when removing more than the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for an item not in the cart", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts known codes" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "normalizes case and whitespace" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), " save10 ")
    end

    test "rejects unknown codes" do
      assert Cart.apply_discount(Cart.new(), "BOGUS") == {:error, :unknown_code}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
    end
  end

  describe "total/2" do
    @prices %{"APPLE" => 150, "PEAR" => 205}

    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart}
    end

    test "charges only shipping for an empty cart" do
      assert Cart.total(Cart.new(), @prices) == 499
    end

    test "sums item prices plus shipping", %{cart: cart} do
      assert Cart.total(cart, @prices) == 300 + 205 + 499
    end

    test "takes 10% off the subtotal with SAVE10, rounded to the nearest cent", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      # 505 - round(50.5) = 454
      assert Cart.total(cart, @prices) == 454 + 499
    end

    test "waives shipping with FREESHIP", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total(cart, @prices) == 505
    end
  end
end

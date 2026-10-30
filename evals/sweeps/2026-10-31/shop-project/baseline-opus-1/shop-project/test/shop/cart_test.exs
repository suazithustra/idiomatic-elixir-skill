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

    test "removes some of the units of an item", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when every unit is removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when more units are removed than the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 4).items == %{}
    end

    test "leaves other items alone", %{cart: cart} do
      cart =
        cart
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 3)

      assert cart.items == %{"PEAR" => 1}
    end

    test "returns the cart unchanged when the item is not in it", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts each known code" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert Cart.apply_discount(Cart.new(), "BOGUS") == {:error, :unknown_code}
      assert Cart.apply_discount(Cart.new(), "save10") == {:error, :unknown_code}
      assert Cart.apply_discount(Cart.new(), "") == {:error, :unknown_code}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
      assert Cart.apply_discount(cart, "SAVE10") == {:error, :discount_already_applied}
    end
  end

  describe "total_price/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 1000, "PEAR" => 500, "PLUM" => 9999}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total_price(cart, prices) == 2500 + 499
    end

    test "charges only shipping for an empty cart", %{prices: prices} do
      assert Cart.total_price(Cart.new(), prices) == 499
    end

    test "SAVE10 takes 10% off the subtotal but not shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")

      assert Cart.total_price(cart, prices) == 2250 + 499
    end

    test "FREESHIP waives the shipping fee", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert Cart.total_price(cart, prices) == 2500
    end

    test "SAVE10 rounds the discount to the nearest cent" do
      {:ok, cart} = Cart.apply_discount(Cart.add_item(Cart.new(), "APPLE", 1), "SAVE10")

      assert Cart.total_price(cart, %{"APPLE" => 999}) == 899 + 499
      assert Cart.total_price(cart, %{"APPLE" => 1001}) == 901 + 499
      assert Cart.total_price(cart, %{"APPLE" => 1005}) == 904 + 499
    end

    test "raises when an item has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_price(cart, %{"APPLE" => 1000}) end
    end
  end
end

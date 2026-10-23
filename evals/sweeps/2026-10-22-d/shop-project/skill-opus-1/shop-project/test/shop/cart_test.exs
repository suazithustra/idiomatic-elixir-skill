defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Shop.Cart

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

    test "decreases the quantity of the item", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when all its units are removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when more units are removed than the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for an item it does not hold", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "applies SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
    end

    test "applies FREESHIP" do
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount(Cart.new(), "save10") == {:error, {:unknown_discount, "save10"}}
    end

    test "returns an error when the cart already holds a code" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
    end
  end

  describe "total/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 150, "PEAR" => 205}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total(cart, prices) == 505 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, rounding the discount down",
         %{cart: cart, prices: prices} do
      assert {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      assert Cart.total(cart, prices) == 505 - 50 + 499
    end

    test "waives the shipping fee with FREESHIP", %{cart: cart, prices: prices} do
      assert {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total(cart, prices) == 505
    end

    test "charges only shipping for an empty cart", %{prices: prices} do
      assert Cart.total(Cart.new(), prices) == 499
    end

    test "raises for a SKU missing from the price list", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total(cart, %{"APPLE" => 150}) end
    end
  end
end

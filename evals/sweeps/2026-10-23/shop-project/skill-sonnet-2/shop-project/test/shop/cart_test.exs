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
    setup do
      %{cart: Cart.add_item(Cart.new(), "APPLE", 3)}
    end

    test "lowers the quantity of the item", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when all its units are removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when more units than held are removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for a SKU not in the cart", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
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

  describe "apply_discount/2" do
    test "accepts SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
    end

    test "accepts FREESHIP" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "replaces the code already on the cart" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(cart, "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount(Cart.new(), "BOGUS") == {:error, {:unknown_code, "BOGUS"}}
    end

    test "returns an error for a code in the wrong case" do
      assert Cart.apply_discount(Cart.new(), "save10") == {:error, {:unknown_code, "save10"}}
    end
  end

  describe "total_price/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 100, "PEAR" => 255, "UNUSED" => 1}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total_price(cart, prices) == 455 + 499
    end

    test "charges shipping on an empty cart", %{prices: prices} do
      assert Cart.total_price(Cart.new(), prices) == 499
    end

    test "takes 10% off the subtotal with SAVE10", %{cart: cart, prices: prices} do
      assert {:ok, cart} = Cart.apply_discount(cart, "SAVE10")

      assert Cart.total_price(cart, prices) == 409 + 499
    end

    test "waives shipping with FREESHIP", %{cart: cart, prices: prices} do
      assert {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert Cart.total_price(cart, prices) == 455
    end

    test "raises for a SKU missing from the price list", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_price(cart, %{"APPLE" => 100}) end
    end
  end
end

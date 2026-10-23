defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Shop.Cart

  @prices %{"APPLE" => 150, "PEAR" => 333}

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
    test "decreases the quantity of the item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 3)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 1}
    end

    test "removes the item when removing exactly the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 3)
        |> Cart.remove_item("APPLE", 3)

      assert cart.items == %{}
    end

    test "removes the item when removing more units than held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 3)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for an item it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 1)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "stores SAVE10 as :save10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
    end

    test "stores FREESHIP as :free_shipping" do
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount(Cart.new(), "save10") ==
               {:error, {:unknown_discount_code, "save10"}}
    end

    test "returns an error when the cart already holds a code" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "FREESHIP")

      assert Cart.apply_discount(cart, "SAVE10") ==
               {:error, {:discount_already_applied, :free_shipping}}
    end
  end

  describe "total/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart} do
      assert Cart.total(cart, @prices) == 633 + 499
    end

    test "takes 10% off the subtotal with SAVE10, rounding halves up", %{cart: cart} do
      assert {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      # 633 * 0.9 = 569.7
      assert Cart.total(cart, @prices) == 570 + 499
    end

    test "waives the shipping fee with FREESHIP", %{cart: cart} do
      assert {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total(cart, @prices) == 633
    end

    test "charges only shipping for an empty cart" do
      assert Cart.total(Cart.new(), @prices) == 499
    end

    test "raises for a SKU missing from the price list", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total(cart, %{"APPLE" => 150}) end
    end
  end
end

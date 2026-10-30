defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Cart

  @prices %{"APPLE" => 150, "PEAR" => 299}

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

    test "lowers the quantity when units remain", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 1).items == %{"APPLE" => 2}
    end

    test "removes the item when every unit is removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when more units are removed than the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 4).items == %{}
    end

    test "leaves other items in the cart", %{cart: cart} do
      cart = Cart.add_item(cart, "PEAR", 1)

      assert Cart.remove_item(cart, "APPLE", 3).items == %{"PEAR" => 1}
    end

    test "returns the cart unchanged for an item it does not hold", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end

    test "keeps the applied discount code", %{cart: cart} do
      assert {:ok, discounted} = Cart.apply_discount(cart, "SAVE10")

      assert Cart.remove_item(discounted, "APPLE", 1).discount == :save10
    end
  end

  describe "apply_discount/2" do
    test "puts SAVE10 on the cart" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
    end

    test "puts FREESHIP on the cart" do
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount(Cart.new(), "SAVE50") ==
               {:error, {:unknown_discount_code, "SAVE50"}}
    end

    test "returns an error for a code in the wrong case" do
      assert Cart.apply_discount(Cart.new(), "save10") ==
               {:error, {:unknown_discount_code, "save10"}}
    end

    test "returns an error for a second code" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
    end
  end

  describe "total_price/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart} do
      assert Cart.total_price(cart, @prices) == 599 + 499
    end

    test "takes 10% off the item subtotal but not the shipping fee with SAVE10", %{cart: cart} do
      assert {:ok, cart} = Cart.apply_discount(cart, "SAVE10")

      assert Cart.total_price(cart, @prices) == 539 + 499
    end

    test "rounds a SAVE10 subtotal down to a whole cent" do
      assert {:ok, cart} = Cart.apply_discount(Cart.add_item(Cart.new(), "PEAR", 1), "SAVE10")

      assert Cart.total_price(cart, %{"PEAR" => 95}) == 85 + 499
    end

    test "waives the shipping fee with FREESHIP", %{cart: cart} do
      assert {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert Cart.total_price(cart, @prices) == 599
    end

    test "charges only the shipping fee for an empty cart" do
      assert Cart.total_price(Cart.new(), @prices) == 499
    end

    test "raises for an item missing from the price list", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_price(cart, %{"APPLE" => 150}) end
    end
  end
end

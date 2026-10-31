defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Shop.Cart

  @price_list %{"APPLE" => 250, "PEAR" => 1000}

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

    test "reduces the quantity when units remain", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when every unit is removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when more units are removed than the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 4).items == %{}
    end

    test "leaves other items in the cart", %{cart: cart} do
      cart =
        cart
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 3)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for a SKU it does not hold", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end

    test "raises for a negative quantity instead of adding units", %{cart: cart} do
      assert_raise FunctionClauseError, fn -> Cart.remove_item(cart, "APPLE", -1) end
    end

    test "keeps the discount of the cart" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      cart =
        cart
        |> Cart.add_item("APPLE", 1)
        |> Cart.remove_item("APPLE", 1)

      assert cart.discount == :save10
    end
  end

  describe "apply_discount/2" do
    test "stores SAVE10 on the cart" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
    end

    test "stores FREESHIP on the cart" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_discount(Cart.new(), "SAVE99") == {:error, {:unknown_discount, "SAVE99"}}
    end

    test "returns an error for a code that differs in case" do
      assert Cart.apply_discount(Cart.new(), "save10") == {:error, {:unknown_discount, "save10"}}
    end

    test "returns an error for a second code when the cart holds one" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
    end

    test "returns an error for the same code applied twice" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert Cart.apply_discount(cart, "SAVE10") == {:error, :discount_already_applied}
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

  describe "total_price/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart} do
      assert Cart.total_price(cart, @price_list) == 1500 + 499
    end

    test "charges only the shipping fee for an empty cart" do
      assert Cart.total_price(Cart.new(), @price_list) == 499
    end

    test "takes 10% off the subtotal but not the shipping fee with SAVE10", %{cart: cart} do
      assert {:ok, cart} = Cart.apply_discount(cart, "SAVE10")

      assert Cart.total_price(cart, @price_list) == 1350 + 499
    end

    test "rounds the SAVE10 subtotal down to a whole cent" do
      assert {:ok, cart} = Cart.apply_discount(Cart.add_item(Cart.new(), "PLUM", 1), "SAVE10")

      assert Cart.total_price(cart, %{"PLUM" => 995}) == 895 + 499
    end

    test "waives the shipping fee with FREESHIP", %{cart: cart} do
      assert {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert Cart.total_price(cart, @price_list) == 1500
    end

    test "raises for an item the price list does not hold", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_price(cart, %{"APPLE" => 250}) end
    end
  end
end

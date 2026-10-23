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

  describe "remove_item/3" do
    test "lowers the quantity of an item" do
      cart = cart_with(%{"APPLE" => 5, "PEAR" => 1})
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 3, "PEAR" => 1}
    end

    test "removes the item when removing every unit it holds" do
      cart = cart_with(%{"APPLE" => 2, "PEAR" => 1})
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"PEAR" => 1}
    end

    test "removes the item when removing more units than the cart holds" do
      cart = cart_with(%{"APPLE" => 2, "PEAR" => 1})
      assert Cart.remove_item(cart, "APPLE", 10).items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged for an item it does not hold" do
      cart = cart_with(%{"PEAR" => 1})
      assert Cart.remove_item(cart, "APPLE", 1) == cart
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
      assert Cart.apply_discount(Cart.new(), "HALFOFF") ==
               {:error, {:unknown_discount_code, "HALFOFF"}}
    end

    test "returns an error when the cart already holds a code" do
      assert {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
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

  describe "total/2" do
    setup do
      %{prices: %{"APPLE" => 250, "PEAR" => 199}}
    end

    test "adds the shipping fee to the item subtotal", %{prices: prices} do
      cart = cart_with(%{"APPLE" => 2, "PEAR" => 1})
      assert Cart.total(cart, prices) == 699 + 499
    end

    test "takes 10% off the item subtotal with SAVE10", %{prices: prices} do
      assert {:ok, cart} = Cart.apply_discount(cart_with(%{"APPLE" => 4}), "SAVE10")
      assert Cart.total(cart, prices) == 900 + 499
    end

    test "rounds the SAVE10 discount to the nearest cent", %{prices: prices} do
      assert {:ok, cart} = Cart.apply_discount(cart_with(%{"APPLE" => 2, "PEAR" => 1}), "SAVE10")
      assert Cart.total(cart, prices) == 699 - 70 + 499
    end

    test "waives the shipping fee with FREESHIP", %{prices: prices} do
      assert {:ok, cart} = Cart.apply_discount(cart_with(%{"APPLE" => 2}), "FREESHIP")
      assert Cart.total(cart, prices) == 500
    end

    test "charges only the shipping fee for an empty cart", %{prices: prices} do
      assert Cart.total(Cart.new(), prices) == 499
    end

    test "raises for an item missing from the price list", %{prices: prices} do
      cart = cart_with(%{"PLUM" => 1})
      assert_raise KeyError, fn -> Cart.total(cart, prices) end
    end
  end

  defp cart_with(items) do
    Enum.reduce(items, Cart.new(), fn {sku, quantity}, cart ->
      Cart.add_item(cart, sku, quantity)
    end)
  end
end

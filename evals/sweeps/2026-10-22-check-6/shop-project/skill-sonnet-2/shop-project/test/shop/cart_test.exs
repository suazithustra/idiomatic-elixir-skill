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

  doctest Shop.Cart

  describe "remove_item/3" do
    setup do
      %{cart: Cart.add_item(Cart.new(), "APPLE", 3)}
    end

    test "reduces the quantity of the item", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when removing exactly the units held", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when removing more units than held", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for a SKU not in the cart", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "applies SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "applies FREESHIP" do
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert Cart.apply_code(Cart.new(), "save10") == {:error, {:unknown_code, "save10"}}
    end

    test "returns an error when the cart already holds a code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert Cart.apply_code(cart, "FREESHIP") == {:error, :code_already_applied}
    end
  end

  describe "total_price/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 1000, "PEAR" => 501}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total_price(cart, prices) == 2501 + 499
    end

    test "takes 10% off the subtotal but not the shipping with SAVE10", %{
      cart: cart,
      prices: prices
    } do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      assert Cart.total_price(cart, prices) == 2251 + 499
    end

    test "waives the shipping fee with FREESHIP", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert Cart.total_price(cart, prices) == 2501
    end

    test "charges only shipping for an empty cart", %{prices: prices} do
      assert Cart.total_price(Cart.new(), prices) == 499
    end

    test "raises for a SKU without a price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_price(cart, %{}) end
    end
  end
end

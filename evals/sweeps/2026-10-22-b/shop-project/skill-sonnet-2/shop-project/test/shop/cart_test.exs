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

  doctest Shop.Cart

  describe "remove_item/3" do
    setup do
      %{cart: Cart.add_item(Cart.new(), "APPLE", 3)}
    end

    test "decreases the quantity of the item", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when removing exactly the units held", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when removing more units than held", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for a SKU it does not hold", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts SAVE10 and FREESHIP" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes, including different casing" do
      assert {:error, {:unknown_code, "save10"}} = Cart.apply_code(Cart.new(), "save10")
      assert {:error, {:unknown_code, "BOGUS"}} = Cart.apply_code(Cart.new(), "BOGUS")
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:error, :code_already_applied} = Cart.apply_code(cart, "FREESHIP")
    end
  end

  describe "total_price/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 3)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 100, "PEAR" => 250}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total_price(cart, prices) == 550 + 499
    end

    test "SAVE10 takes 10% off the subtotal but not the shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert Cart.total_price(cart, prices) == 495 + 499
    end

    test "FREESHIP waives the shipping fee", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert Cart.total_price(cart, prices) == 550
    end

    test "an empty cart still pays shipping", %{prices: prices} do
      assert Cart.total_price(Cart.new(), prices) == 499
    end

    test "raises when a SKU has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total_price(cart, %{"APPLE" => 100}) end
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
end

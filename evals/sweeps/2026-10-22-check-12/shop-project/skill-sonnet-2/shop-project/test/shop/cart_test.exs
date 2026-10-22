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
    setup do
      %{cart: Cart.add_item(Cart.new(), "APPLE", 3)}
    end

    test "decrements the quantity", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when removing exactly what is held", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when removing more than is held", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for a SKU not in the cart", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount_code/2" do
    test "accepts SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount_code(Cart.new(), "SAVE10")
    end

    test "accepts FREESHIP" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount_code(Cart.new(), "FREESHIP")
    end

    test "rejects an unknown code" do
      assert Cart.apply_discount_code(Cart.new(), "save10") ==
               {:error, {:unknown_discount_code, "save10"}}
    end

    test "rejects a second code" do
      assert {:ok, cart} = Cart.apply_discount_code(Cart.new(), "SAVE10")
      assert Cart.apply_discount_code(cart, "FREESHIP") == {:error, :discount_already_applied}
    end
  end

  describe "total/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 1000, "PEAR" => 555}}
    end

    test "adds the shipping fee to the subtotal", %{cart: cart, prices: prices} do
      assert Cart.total(cart, prices) == {:ok, 2555 + 499}
    end

    test "takes 10% off the items but not the shipping with SAVE10", %{cart: cart, prices: prices} do
      assert {:ok, cart} = Cart.apply_discount_code(cart, "SAVE10")
      assert Cart.total(cart, prices) == {:ok, 2299 + 499}
    end

    test "waives shipping with FREESHIP", %{cart: cart, prices: prices} do
      assert {:ok, cart} = Cart.apply_discount_code(cart, "FREESHIP")
      assert Cart.total(cart, prices) == {:ok, 2555}
    end

    test "returns an error for a SKU missing from the price list", %{cart: cart} do
      assert Cart.total(cart, %{"APPLE" => 1000}) == {:error, {:unknown_sku, "PEAR"}}
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

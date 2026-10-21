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

    test "removes some units", %{cart: cart} do
      assert %Cart{items: %{"APPLE" => 1}} = Cart.remove_item(cart, "APPLE", 2)
    end

    test "removes the item when removing exactly the units held", %{cart: cart} do
      assert %Cart{items: items} = Cart.remove_item(cart, "APPLE", 3)
      assert items == %{}
    end

    test "removes the item when removing more units than held", %{cart: cart} do
      assert %Cart{items: items} = Cart.remove_item(cart, "APPLE", 10)
      assert items == %{}
    end

    test "leaves the cart unchanged for a SKU not in the cart", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts known codes" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes, including wrong case" do
      assert {:error, {:unknown_discount, "BOGUS"}} = Cart.apply_discount(Cart.new(), "BOGUS")
      assert {:error, {:unknown_discount, "save10"}} = Cart.apply_discount(Cart.new(), "save10")
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:error, :discount_already_applied} = Cart.apply_discount(cart, "FREESHIP")
      assert {:error, :discount_already_applied} = Cart.apply_discount(cart, "SAVE10")
    end
  end

  describe "total_price/2" do
    setup do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1)
      %{cart: cart, prices: %{"APPLE" => 300, "PEAR" => 250}}
    end

    test "adds shipping to the subtotal", %{cart: cart, prices: prices} do
      assert {:ok, 1349} = Cart.total_price(cart, prices)
    end

    test "SAVE10 takes 10% off the subtotal but not shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      assert {:ok, 1264} = Cart.total_price(cart, prices)
    end

    test "FREESHIP waives shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert {:ok, 850} = Cart.total_price(cart, prices)
    end

    test "an empty cart pays shipping" do
      assert {:ok, 499} = Cart.total_price(Cart.new(), %{})
    end

    test "returns an error for a SKU without a price", %{cart: cart} do
      assert {:error, {:unknown_sku, "PEAR"}} = Cart.total_price(cart, %{"APPLE" => 300})
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

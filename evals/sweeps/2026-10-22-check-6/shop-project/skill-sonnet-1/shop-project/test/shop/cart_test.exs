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

    test "decreases the quantity of the item", %{cart: cart} do
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

  describe "apply_discount/2" do
    test "stores a known code on the cart" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "returns an error for an unknown code" do
      assert {:error, {:unknown_code, "save10"}} = Cart.apply_discount(Cart.new(), "save10")
    end

    test "returns an error when the cart already holds a code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert {:error, :discount_already_applied} = Cart.apply_discount(cart, "FREESHIP")
      assert {:error, :discount_already_applied} = Cart.apply_discount(cart, "SAVE10")
    end
  end

  describe "total_cents/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 250, "PEAR" => 333, "KIWI" => 1}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total_cents(cart, prices) == {:ok, 833 + 499}
    end

    test "takes 10% off the subtotal but not the shipping with SAVE10", %{
      cart: cart,
      prices: prices
    } do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")

      assert Cart.total_cents(cart, prices) == {:ok, 750 + 499}
    end

    test "waives the shipping fee with FREESHIP", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert Cart.total_cents(cart, prices) == {:ok, 833}
    end

    test "charges only shipping for an empty cart", %{prices: prices} do
      assert Cart.total_cents(Cart.new(), prices) == {:ok, 499}
    end

    test "returns an error for a SKU missing from the price list", %{cart: cart} do
      assert Cart.total_cents(cart, %{"APPLE" => 250}) == {:error, {:unknown_sku, "PEAR"}}
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

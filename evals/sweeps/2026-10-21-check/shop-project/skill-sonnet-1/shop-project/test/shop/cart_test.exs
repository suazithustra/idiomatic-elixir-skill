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

  describe "remove_item/3" do
    setup do
      %{cart: Cart.add_item(Cart.new(), "APPLE", 3)}
    end

    test "decreases the quantity of the item", %{cart: cart} do
      assert %Cart{items: %{"APPLE" => 1}} = Cart.remove_item(cart, "APPLE", 2)
    end

    test "removes the item when exactly its quantity is removed", %{cart: cart} do
      assert %Cart{items: items} = Cart.remove_item(cart, "APPLE", 3)
      assert items == %{}
    end

    test "removes the item when more than its quantity is removed", %{cart: cart} do
      assert %Cart{items: items} = Cart.remove_item(cart, "APPLE", 10)
      assert items == %{}
    end

    test "leaves the cart unchanged for a SKU that is not in it", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts SAVE10 and FREESHIP" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert {:error, :unknown_code} = Cart.apply_code(Cart.new(), "save10")
      assert {:error, :unknown_code} = Cart.apply_code(Cart.new(), "")
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert {:error, :code_already_applied} = Cart.apply_code(cart, "FREESHIP")
      assert {:error, :code_already_applied} = Cart.apply_code(cart, "SAVE10")
    end
  end

  describe "total_price/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 1000, "PEAR" => 500}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert {:ok, 2999} = Cart.total_price(cart, prices)
    end

    test "takes 10% off the subtotal but not the shipping fee", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      assert {:ok, 2749} = Cart.total_price(cart, prices)
    end

    test "rounds the SAVE10 discount to the nearest cent" do
      cart = Cart.add_item(Cart.new(), "APPLE", 1)
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      assert {:ok, 540} = Cart.total_price(cart, %{"APPLE" => 45})
    end

    test "waives the shipping fee with FREESHIP", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert {:ok, 2500} = Cart.total_price(cart, prices)
    end

    test "charges only shipping for an empty cart" do
      assert {:ok, 499} = Cart.total_price(Cart.new(), %{})
    end

    test "returns an error for a SKU missing from the price list", %{cart: cart} do
      assert {:error, {:unknown_sku, "PEAR"}} = Cart.total_price(cart, %{"APPLE" => 1000})
    end
  end

  doctest Shop.Cart
end

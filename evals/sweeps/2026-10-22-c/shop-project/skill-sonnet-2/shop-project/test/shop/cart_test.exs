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
    test "decreases the quantity of an item" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 5)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when removing exactly the units held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.remove_item("APPLE", 2)

      assert cart.items == %{}
    end

    test "removes the item when removing more units than held" do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)
        |> Cart.remove_item("APPLE", 10)

      assert cart.items == %{"PEAR" => 1}
    end

    test "leaves the cart alone for an SKU it does not hold" do
      cart = Cart.add_item(Cart.new(), "APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts known codes" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert Cart.apply_code(Cart.new(), "save10") == {:error, {:unknown_code, "save10"}}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert Cart.apply_code(cart, "FREESHIP") == {:error, {:code_already_applied, :save10}}
    end
  end

  describe "total/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 100, "PEAR" => 250}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total(cart, prices) == {:ok, 450 + 499}
    end

    test "SAVE10 takes 10% off the subtotal only", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert Cart.total(cart, prices) == {:ok, 405 + 499}
    end

    test "FREESHIP waives the shipping fee", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert Cart.total(cart, prices) == {:ok, 450}
    end

    test "an empty cart still pays shipping", %{prices: prices} do
      assert Cart.total(Cart.new(), prices) == {:ok, 499}
    end

    test "errors on an SKU missing from the price list", %{cart: cart} do
      assert Cart.total(cart, %{"APPLE" => 100}) == {:error, {:unknown_sku, "PEAR"}}
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

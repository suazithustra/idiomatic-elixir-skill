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

    test "removes the item when exactly its quantity is removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when more than its quantity is removed", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for a SKU it does not hold", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
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

  describe "apply_code/2" do
    test "applies SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "applies FREESHIP" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes, including different casing" do
      assert {:error, {:unknown_code, "save10"}} = Cart.apply_code(Cart.new(), "save10")
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:error, :code_already_applied} = Cart.apply_code(cart, "FREESHIP")
      assert {:error, :code_already_applied} = Cart.apply_code(cart, "SAVE10")
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

    test "adds the shipping fee to the subtotal", %{cart: cart, prices: prices} do
      assert Cart.total(cart, prices) == {:ok, 450 + 499}
    end

    test "takes 10% off the subtotal for SAVE10", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert Cart.total(cart, prices) == {:ok, 405 + 499}
    end

    test "waives shipping for FREESHIP", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert Cart.total(cart, prices) == {:ok, 450}
    end

    test "charges only shipping for an empty cart", %{prices: prices} do
      assert Cart.total(Cart.new(), prices) == {:ok, 499}
    end

    test "returns an error for a SKU missing from the price list", %{cart: cart} do
      assert Cart.total(cart, %{"APPLE" => 100}) == {:error, {:unknown_sku, "PEAR"}}
    end
  end
end

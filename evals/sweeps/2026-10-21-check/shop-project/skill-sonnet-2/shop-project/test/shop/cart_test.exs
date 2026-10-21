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

  describe "apply_code/2" do
    test "applies SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "applies FREESHIP" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert {:error, {:unknown_code, "save10"}} = Cart.apply_code(Cart.new(), "save10")
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:error, :code_already_applied} = Cart.apply_code(cart, "FREESHIP")
    end
  end

  describe "total/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 1000, "PEAR" => 250}}
    end

    test "adds the shipping fee to the item subtotal", %{cart: cart, prices: prices} do
      assert {:ok, 2749} = Cart.total(cart, prices)
    end

    test "takes 10% off the item subtotal with SAVE10", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert {:ok, 2524} = Cart.total(cart, prices)
    end

    test "waives shipping with FREESHIP", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert {:ok, 2250} = Cart.total(cart, prices)
    end

    test "rounds the SAVE10 discount to the nearest cent" do
      cart = Cart.add_item(Cart.new(), "GUM", 1)
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert {:ok, 604} = Cart.total(cart, %{"GUM" => 117})
    end

    test "returns an error for a SKU without a price", %{cart: cart} do
      assert {:error, {:unknown_sku, _sku}} = Cart.total(cart, %{"APPLE" => 1000})
    end
  end

  doctest Shop.Cart
end

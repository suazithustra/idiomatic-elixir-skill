defmodule Shop.CartTest do
  use ExUnit.Case, async: true

  alias Shop.Cart

  doctest Cart

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

    test "decreases the quantity", %{cart: cart} do
      assert %Cart{items: %{"APPLE" => 1}} = Cart.remove_item(cart, "APPLE", 2)
    end

    test "removes the item when removing exactly the held units", %{cart: cart} do
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
    test "accepts SAVE10" do
      assert {:ok, %Cart{code: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "accepts FREESHIP" do
      assert {:ok, %Cart{code: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
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

    test "reports an unknown code before an already applied one" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:error, :unknown_code} = Cart.apply_code(cart, "BOGUS")
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
      assert {:ok, 949} = Cart.total(cart, prices)
    end

    test "charges shipping on an empty cart", %{prices: prices} do
      assert {:ok, 499} = Cart.total(Cart.new(), prices)
    end

    test "SAVE10 takes 10% off the subtotal but not the shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert {:ok, 904} = Cart.total(cart, prices)
    end

    test "SAVE10 rounds halves up to the nearest cent" do
      {:ok, cart} = Cart.apply_code(Cart.add_item(Cart.new(), "APPLE", 1), "SAVE10")
      assert {:ok, 589} = Cart.total(cart, %{"APPLE" => 100})
      assert {:ok, 593} = Cart.total(cart, %{"APPLE" => 105})
    end

    test "FREESHIP waives the shipping fee", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert {:ok, 450} = Cart.total(cart, prices)
    end

    test "returns an error for a SKU missing from the price list", %{cart: cart} do
      assert {:error, {:unknown_sku, "PEAR"}} = Cart.total(cart, %{"APPLE" => 100})
    end
  end
end

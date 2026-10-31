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

  describe "remove_item/3" do
    setup do
      %{cart: Cart.add_item(Cart.new(), "APPLE", 5)}
    end

    test "reduces the quantity", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 3}
    end

    test "removes the item when removing exactly the held quantity", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 5).items == %{}
    end

    test "removes the item when removing more than the held quantity", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 9).items == %{}
    end

    test "ignores a SKU not in the cart", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_code/2" do
    test "accepts known codes" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, :unknown_code}
      assert Cart.apply_code(Cart.new(), "save10") == {:error, :unknown_code}
      assert Cart.apply_code(Cart.new(), "") == {:error, :unknown_code}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")
      assert Cart.apply_code(cart, "FREESHIP") == {:error, :code_already_applied}
    end
  end

  describe "total_price/2" do
    @prices %{"APPLE" => 100, "PEAR" => 250}

    setup do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1)
      %{cart: cart}
    end

    test "adds shipping to the subtotal", %{cart: cart} do
      assert Cart.total_price(cart, @prices) == {:ok, 450 + 499}
    end

    test "SAVE10 takes 10% off the subtotal but not shipping", %{cart: cart} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")
      assert Cart.total_price(cart, @prices) == {:ok, 405 + 499}
    end

    test "FREESHIP waives shipping", %{cart: cart} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")
      assert Cart.total_price(cart, @prices) == {:ok, 450}
    end

    test "empty cart still pays shipping" do
      assert Cart.total_price(Cart.new(), @prices) == {:ok, 499}
    end

    test "errors on a SKU without a price", %{cart: cart} do
      assert Cart.total_price(cart, %{"APPLE" => 100}) == {:error, {:unknown_sku, "PEAR"}}
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

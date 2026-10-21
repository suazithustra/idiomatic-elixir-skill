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

    test "decreases the quantity of an item", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1}
    end

    test "removes the item when removing exactly its quantity", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when removing more than its quantity", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged for a SKU not in the cart", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts SAVE10 and FREESHIP" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "ignores case and surrounding whitespace" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "  save10 ")
    end

    test "rejects unknown codes" do
      assert Cart.apply_discount(Cart.new(), "SAVE50") == {:error, :unknown_code}
      assert Cart.apply_discount(Cart.new(), "") == {:error, :unknown_code}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")

      assert Cart.apply_discount(cart, "FREESHIP") == {:error, :discount_already_applied}
      assert Cart.apply_discount(cart, "SAVE10") == {:error, :discount_already_applied}
    end
  end

  describe "total/2" do
    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 1)

      %{cart: cart, prices: %{"APPLE" => 150, "PEAR" => 200, "PLUM" => 999}}
    end

    test "sums item prices and adds shipping", %{cart: cart, prices: prices} do
      assert Cart.total(cart, prices) == 2 * 150 + 200 + 499
    end

    test "charges only shipping for an empty cart", %{prices: prices} do
      assert Cart.total(Cart.new(), prices) == 499
    end

    test "SAVE10 takes 10% off the item subtotal but not shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      assert Cart.total(cart, prices) == 450 + 499
    end

    test "SAVE10 rounds the discount to the nearest cent", %{prices: prices} do
      {:ok, cart} = Cart.new() |> Cart.add_item("PLUM", 1) |> Cart.apply_discount("SAVE10")
      # 10% of 999 is 99.9, rounded to 100.
      assert Cart.total(cart, prices) == 899 + 499
    end

    test "FREESHIP waives shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total(cart, prices) == 500
    end

    test "raises when a SKU has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total(cart, %{"APPLE" => 150}) end
    end
  end
end

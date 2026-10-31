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
      %{cart: Cart.new() |> Cart.add_item("APPLE", 3) |> Cart.add_item("PEAR", 1)}
    end

    test "reduces the quantity of an item", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 2).items == %{"APPLE" => 1, "PEAR" => 1}
    end

    test "removes the item when no units remain", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{"PEAR" => 1}
    end

    test "removes the item when removing more units than the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 4).items == %{"PEAR" => 1}
    end

    test "leaves the cart unchanged when the item is not in it", %{cart: cart} do
      assert Cart.remove_item(cart, "PLUM", 1) == cart
    end

    test "keeps the applied discount", %{cart: cart} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      assert Cart.remove_item(cart, "PEAR", 1).discount == :save10
    end

    test "rejects a quantity that is not positive", %{cart: cart} do
      assert_raise FunctionClauseError, fn -> Cart.remove_item(cart, "APPLE", 0) end
    end
  end

  describe "apply_code/2" do
    test "accepts SAVE10" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_code(Cart.new(), "SAVE10")
    end

    test "accepts FREESHIP" do
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_code(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert Cart.apply_code(Cart.new(), "BOGUS") == {:error, :unknown_code}
      assert Cart.apply_code(Cart.new(), "") == {:error, :unknown_code}
      assert Cart.apply_code(Cart.new(), "save10") == {:error, :unknown_code}
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_code(Cart.new(), "SAVE10")

      assert Cart.apply_code(cart, "FREESHIP") == {:error, :code_already_applied}
      assert Cart.apply_code(cart, "SAVE10") == {:error, :code_already_applied}
    end
  end

  describe "total/2" do
    setup do
      %{
        cart: Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.add_item("PEAR", 1),
        prices: %{"APPLE" => 1000, "PEAR" => 500, "PLUM" => 9999}
      }
    end

    test "adds shipping to the item subtotal", %{cart: cart, prices: prices} do
      assert Cart.total(cart, prices) == 2500 + 499
    end

    test "SAVE10 takes 10% off the items but not shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "SAVE10")

      assert Cart.total(cart, prices) == 2250 + 499
    end

    test "FREESHIP waives shipping", %{cart: cart, prices: prices} do
      {:ok, cart} = Cart.apply_code(cart, "FREESHIP")

      assert Cart.total(cart, prices) == 2500
    end

    test "rounds the SAVE10 discount to the nearest cent" do
      {:ok, cart} = Cart.new() |> Cart.add_item("APPLE", 1) |> Cart.apply_code("SAVE10")

      assert Cart.total(cart, %{"APPLE" => 1994}) == 1795 + 499
      assert Cart.total(cart, %{"APPLE" => 1995}) == 1795 + 499
      assert Cart.total(cart, %{"APPLE" => 1999}) == 1799 + 499
    end

    test "charges only shipping for an empty cart", %{prices: prices} do
      assert Cart.total(Cart.new(), prices) == 499
    end

    test "raises when an item has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total(cart, %{"APPLE" => 1000}) end
    end
  end
end

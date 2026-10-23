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

    test "removes the item when removing exactly what the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 3).items == %{}
    end

    test "removes the item when removing more than the cart holds", %{cart: cart} do
      assert Cart.remove_item(cart, "APPLE", 10).items == %{}
    end

    test "leaves the cart unchanged when the item is not in it", %{cart: cart} do
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "applies a known code" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :free_shipping}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "ignores case and surrounding whitespace" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "  save10 ")
    end

    test "rejects an unknown code" do
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
    @prices %{"APPLE" => 250, "PEAR" => 199}

    setup do
      cart =
        Cart.new()
        |> Cart.add_item("APPLE", 2)
        |> Cart.add_item("PEAR", 5)

      %{cart: cart}
    end

    test "adds shipping to the item subtotal", %{cart: cart} do
      assert Cart.total(cart, @prices) == 1495 + 499
    end

    test "takes 10% off the item subtotal with SAVE10, rounding to the nearest cent",
         %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")

      # 10% of 1495 is 149.5, rounded to 150.
      assert Cart.total(cart, @prices) == 1495 - 150 + 499
    end

    test "waives shipping with FREESHIP", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")

      assert Cart.total(cart, @prices) == 1495
    end

    test "is 0 for an empty cart" do
      assert Cart.total(Cart.new(), @prices) == 0
    end

    test "raises when a SKU has no price", %{cart: cart} do
      assert_raise KeyError, fn -> Cart.total(cart, %{"APPLE" => 250}) end
    end
  end
end

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
    test "removes some units" do
      cart = Cart.new() |> Cart.add_item("APPLE", 5) |> Cart.remove_item("APPLE", 2)
      assert cart.items == %{"APPLE" => 3}
    end

    test "removes the item when removing exactly the held units" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.remove_item("APPLE", 2)
      assert cart.items == %{}
    end

    test "removes the item when removing more units than held" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2) |> Cart.remove_item("APPLE", 9)
      assert cart.items == %{}
    end

    test "ignores an item not in the cart" do
      cart = Cart.new() |> Cart.add_item("APPLE", 2)
      assert Cart.remove_item(cart, "PEAR", 1) == cart
    end
  end

  describe "apply_discount/2" do
    test "accepts known codes" do
      assert {:ok, %Cart{discount: :save10}} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:ok, %Cart{discount: :freeship}} = Cart.apply_discount(Cart.new(), "FREESHIP")
    end

    test "rejects unknown codes" do
      assert {:error, :unknown_code} = Cart.apply_discount(Cart.new(), "BOGUS")
      assert {:error, :unknown_code} = Cart.apply_discount(Cart.new(), "save10")
    end

    test "rejects a second code" do
      {:ok, cart} = Cart.apply_discount(Cart.new(), "SAVE10")
      assert {:error, :code_already_applied} = Cart.apply_discount(cart, "FREESHIP")
      assert {:error, :code_already_applied} = Cart.apply_discount(cart, "SAVE10")
    end
  end

  describe "total_cents/2" do
    @prices %{"APPLE" => 100, "PEAR" => 250}

    setup do
      %{cart: Cart.new() |> Cart.add_item("APPLE", 3) |> Cart.add_item("PEAR", 1)}
    end

    test "adds shipping to the subtotal", %{cart: cart} do
      assert Cart.total_cents(cart, @prices) == {:ok, 550 + 499}
    end

    test "SAVE10 takes 10% off the subtotal only", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "SAVE10")
      assert Cart.total_cents(cart, @prices) == {:ok, 495 + 499}
    end

    test "FREESHIP waives shipping", %{cart: cart} do
      {:ok, cart} = Cart.apply_discount(cart, "FREESHIP")
      assert Cart.total_cents(cart, @prices) == {:ok, 550}
    end

    test "an empty cart still pays shipping" do
      assert Cart.total_cents(Cart.new(), @prices) == {:ok, 499}
    end

    test "reports a SKU with no price", %{cart: cart} do
      assert Cart.total_cents(cart, %{"APPLE" => 100}) == {:error, {:unknown_sku, "PEAR"}}
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

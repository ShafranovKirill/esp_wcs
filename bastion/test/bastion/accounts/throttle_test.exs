defmodule Bastion.Accounts.Domain.ThrottleTest do
  use ExUnit.Case, async: true

  alias Bastion.Accounts.Domain.Throttle

  test "5 ошибок без паузы, дальше 5 с с удвоением до 15 минут" do
    throttle = Enum.reduce(1..5, Throttle.new(), fn _, t -> Throttle.failure(t, 0) end)
    assert Throttle.wait_seconds(throttle, 0) == 0

    throttle = Throttle.failure(throttle, 100)
    assert Throttle.wait_seconds(throttle, 100) == 5
    assert Throttle.wait_seconds(throttle, 105) == 0

    throttle = Throttle.failure(throttle, 200)
    assert Throttle.wait_seconds(throttle, 200) == 10

    throttle = Enum.reduce(1..20, throttle, fn _, t -> Throttle.failure(t, 300) end)
    assert Throttle.wait_seconds(throttle, 300) == 15 * 60
  end
end

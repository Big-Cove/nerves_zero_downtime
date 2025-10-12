defmodule NervesZeroDowntimeTest do
  use ExUnit.Case
  doctest NervesZeroDowntime

  test "module loads successfully" do
    assert Code.ensure_loaded?(NervesZeroDowntime)
  end
end

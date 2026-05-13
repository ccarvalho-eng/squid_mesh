defmodule SquidMesh.Runtime.StepInputTest do
  use ExUnit.Case, async: true

  alias SquidMesh.Runtime.StepInput

  test "normalizes nested maps without treating exception structs as enumerables" do
    error = %RuntimeError{message: "boom"}

    assert StepInput.normalize_map_keys(%{"details" => %{"original_exception" => error}}) == %{
             details: %{original_exception: error}
           }
  end
end

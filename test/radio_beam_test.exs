defmodule RadioBeamTest do
  use ExUnit.Case

  describe "versions/0" do
    test "returns a list of supported `versions`" do
      assert %{versions: versions} = RadioBeam.versions()
      assert is_list(versions)
      # "Values will take the form vX.Y or rX.Y.Z in historical cases"
      assert Enum.all?(versions, &String.starts_with?(&1, ["v", "r"]))
    end
  end
end

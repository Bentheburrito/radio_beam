defmodule RadioBeam.CrednetialsTest do
  alias RadioBeam.Credentials
  use ExUnit.Case, async: true

  describe "strong_password?/1" do
    @special_chars ~w|! @ # $ % ^ & * ( ) _ - + = { [ } ] \| \ : ; " ' < , > . ? /|
    @digits ~w|1 2 3 4 5 6 7 8 9 0|
    @letters ~w|a b c d e f g h i j k l m n o p q r s t u v w x y z|
    @upper_letters Enum.map(@letters, &String.upcase/1)

    test "returns true for passwords that satisfy the regex" do
      for _ <- 1..100, sets <- [Enum.shuffle([@special_chars, @digits, @letters, @upper_letters])] do
        password =
          for set <- sets, character <- Enum.take_random(set, Enum.random(2..6)), into: "" do
            character
          end

        assert {_, true} = {password, Credentials.strong_password?(password)}
      end
    end

    test "returns false for passwords that don't satisfy the regex" do
      for _ <- 1..100, sets <- [Enum.shuffle([@special_chars, @digits, @letters, @upper_letters])] do
        password =
          for set <- Enum.take(sets, 3), character <- Enum.take_random(set, Enum.random(3..6)), into: "" do
            character
          end

        assert {_, false} = {password, Credentials.strong_password?(password)}
      end
    end

    # too short
    refute Credentials.strong_password?("t00SML!")
  end
end

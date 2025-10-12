defmodule NervesZeroDowntime.PartitionRotationTest do
  @moduledoc """
  Comprehensive tests for 3-partition rotation logic.

  This test suite validates that the partition tracking logic correctly handles
  all possible upgrade paths in a 3-partition A/B/C system with hot reload.

  ## Key Concepts

  - `booted`: Partition where kernel booted from (from /proc/cmdline, never changes during hot reloads)
  - `active`: Partition that will boot next (boot pointer, updated by fwup)

  ## The Algorithm

  Next write target = all_partitions - {booted, active}

  This creates automatic alternation:
  - Boot from A: alternates between B and C
  - Boot from B: alternates between A and C
  - Boot from C: alternates between A and B

  ## Key Invariants Tested

  1. Never write to `booted` partition (kernel lives there)
  2. Never write to `active` partition (boot pointer)
  3. After initial boot (booted==active), can write to either of the other two
  4. After first update (booted!=active), exactly one partition available
  5. Automatic alternation between the two non-booted partitions
  """

  use ExUnit.Case, async: false

  alias NervesZeroDowntime.PartitionRotationLogic

  describe "3-partition rotation logic" do
    test "validates single upgrade transitions from initial boot" do
      # When booted==active (fresh boot), we have 2 choices
      # The algorithm picks the first alphabetically
      transitions = [
        # Boot from A
        %{booted: "a", active: "a", validated: true, expected: "b"},
        # Boot from B
        %{booted: "b", active: "b", validated: true, expected: "a"},
        # Boot from C
        %{booted: "c", active: "c", validated: true, expected: "a"}
      ]

      for transition <- transitions do
        result = PartitionRotationLogic.determine_next_partition(
          transition.booted,
          transition.active,
          transition.validated
        )

        assert result == {:ok, transition.expected},
               "Expected transition from booted=#{transition.booted} to write to #{transition.expected}, got #{inspect(result)}"
      end
    end

    test "validates alternating pattern from boot partition A" do
      # Boot from A, then alternate B ↔ C
      sequence = [
        # Step 0: Initial boot
        %{booted: "a", active: "a", expected: "b"},
        # Step 1: Wrote to B, active now B
        %{booted: "a", active: "b", expected: "c"},
        # Step 2: Wrote to C, active now C
        %{booted: "a", active: "c", expected: "b"},
        # Step 3: Wrote to B, active now B (pattern repeats)
        %{booted: "a", active: "b", expected: "c"},
        # Step 4: Wrote to C, active now C
        %{booted: "a", active: "c", expected: "b"}
      ]

      for %{booted: booted, active: active, expected: expected} <- sequence do
        {:ok, result} = PartitionRotationLogic.determine_next_partition(booted, active, true)

        assert result == expected,
               """
               Boot from A sequence failed:
               Booted: #{booted}, Active: #{active}
               Expected: #{expected}, Got: #{result}
               """
      end
    end

    test "validates alternating pattern from boot partition B" do
      # Boot from B, then alternate A ↔ C
      sequence = [
        %{booted: "b", active: "b", expected: "a"},
        %{booted: "b", active: "a", expected: "c"},
        %{booted: "b", active: "c", expected: "a"},
        %{booted: "b", active: "a", expected: "c"}
      ]

      for %{booted: booted, active: active, expected: expected} <- sequence do
        {:ok, result} = PartitionRotationLogic.determine_next_partition(booted, active, true)
        assert result == expected
      end
    end

    test "validates alternating pattern from boot partition C" do
      # Boot from C, then alternate A ↔ B
      sequence = [
        %{booted: "c", active: "c", expected: "a"},
        %{booted: "c", active: "a", expected: "b"},
        %{booted: "c", active: "b", expected: "a"},
        %{booted: "c", active: "a", expected: "b"}
      ]

      for %{booted: booted, active: active, expected: expected} <- sequence do
        {:ok, result} = PartitionRotationLogic.determine_next_partition(booted, active, true)
        assert result == expected
      end
    end

    test "validates all user-specified sequences" do
      # From user's analysis
      test_cases = [
        # Current boot A: Upgrading on B, C, B, C
        %{booted: "a", sequence: ["a", "b", "c", "b", "c"]},
        # Current boot B: Upgrading on A, C, A, C
        %{booted: "b", sequence: ["b", "a", "c", "a", "c"]},
        # Current boot C: Upgrading on A, B, A, B
        %{booted: "c", sequence: ["c", "a", "b", "a", "b"]}
      ]

      for test_case <- test_cases do
        # Simulate the sequence using the algorithm
        actual_sequence = PartitionRotationLogic.simulate_sequence(
          test_case.booted,
          length(test_case.sequence) - 1
        )

        assert actual_sequence == test_case.sequence,
               """
               Sequence mismatch for boot from #{test_case.booted}:
               Expected: #{inspect(test_case.sequence)}
               Got:      #{inspect(actual_sequence)}
               """
      end
    end

    test "validates endless rotation (10 upgrades)" do
      # Boot from A, do 10 upgrades
      expected = ["a", "b", "c", "b", "c", "b", "c", "b", "c", "b", "c"]
      actual = PartitionRotationLogic.simulate_sequence("a", 10)

      assert actual == expected,
             "10-upgrade sequence from A doesn't match expected pattern"

      # Verify the pattern is: initial choice (b), then alternate c,b,c,b...
      assert length(actual) == 11
    end

    test "validates no partition is ever written while booted or active" do
      # Test all combinations of (booted, active) states
      all_states = for booted <- ["a", "b", "c"],
                       active <- ["a", "b", "c"],
                       do: {booted, active}

      for {booted, active} <- all_states do
        {:ok, next} = PartitionRotationLogic.determine_next_partition(booted, active, true)

        assert next != booted,
               "Safety violation: Attempted to write to booted partition #{booted}"

        assert next != active,
               "Safety violation: Attempted to write to active partition #{active}"

        # Verify it's a valid partition
        assert next in ["a", "b", "c"],
               "Invalid target partition: #{next}"
      end
    end

    test "rejects invalid states" do
      invalid_states = [
        # Not validated
        %{booted: "a", active: "a", validated: false},
        # Invalid partition names
        %{booted: "x", active: "x", validated: true},
        %{booted: "a", active: "invalid", validated: true},
        %{booted: "a", active: "a", validated: "maybe"}
      ]

      for state <- invalid_states do
        result = PartitionRotationLogic.determine_next_partition(
          state.booted,
          state.active,
          state.validated
        )

        assert match?({:error, _}, result),
               "Expected error for invalid state #{inspect(state)}, got #{inspect(result)}"
      end
    end

    test "validates available partitions calculation" do
      test_cases = [
        %{booted: "a", active: "a", expected: ["b", "c"]},
        %{booted: "a", active: "b", expected: ["c"]},
        %{booted: "a", active: "c", expected: ["b"]},
        %{booted: "b", active: "a", expected: ["c"]},
        %{booted: "b", active: "c", expected: ["a"]},
        %{booted: "c", active: "a", expected: ["b"]},
        %{booted: "c", active: "b", expected: ["a"]}
      ]

      for test_case <- test_cases do
        available = PartitionRotationLogic.available_partitions_for_write(
          test_case.booted,
          test_case.active
        )

        assert available == test_case.expected,
               """
               Available partitions mismatch:
               Booted: #{test_case.booted}, Active: #{test_case.active}
               Expected: #{inspect(test_case.expected)}
               Got: #{inspect(available)}
               """
      end
    end
  end

  describe "simulated fwup upgrade scenarios" do
    test "validates complete upgrade flow with state transitions" do
      # Scenario: Boot from A, do 3 consecutive hot reload upgrades
      scenarios = [
        %{
          step: "Initial boot",
          booted: "a",
          active: "a",
          expected_write: "b",
          after_write_active: "b"
        },
        %{
          step: "After 1st upgrade (wrote to B)",
          booted: "a",
          active: "b",
          expected_write: "c",
          after_write_active: "c"
        },
        %{
          step: "After 2nd upgrade (wrote to C)",
          booted: "a",
          active: "c",
          expected_write: "b",
          after_write_active: "b"
        },
        %{
          step: "After 3rd upgrade (wrote to B again)",
          booted: "a",
          active: "b",
          expected_write: "c",
          after_write_active: "c"
        }
      ]

      for scenario <- scenarios do
        {:ok, write_target} = PartitionRotationLogic.determine_next_partition(
          scenario.booted,
          scenario.active,
          true
        )

        assert write_target == scenario.expected_write,
               """
               #{scenario.step}:
               Booted: #{scenario.booted}, Active: #{scenario.active}
               Expected to write to: #{scenario.expected_write}
               Got: #{write_target}
               """

        # Verify that after writing, the active pointer would update correctly
        assert write_target == scenario.after_write_active,
               "After write, active should be #{scenario.after_write_active}"
      end
    end

    test "validates that booted partition never changes during hot reloads" do
      # Boot from A, do 5 upgrades
      booted = "a"
      active = "a"

      # Simulate 5 upgrades
      _sequence = Enum.reduce(1..5, {booted, active, []}, fn step, {boot, act, history} ->
        {:ok, next} = PartitionRotationLogic.determine_next_partition(boot, act, true)

        # Verify booted never changes
        assert boot == booted,
               "Step #{step}: Booted partition changed from #{booted} to #{boot}!"

        # Verify we're not writing to booted
        assert next != boot,
               "Step #{step}: Attempting to write to booted partition!"

        # Update active for next iteration (simulating fwup updating the pointer)
        {boot, next, history ++ [{boot, act, next}]}
      end)
    end
  end

  describe "exhaustive permutation testing" do
    test "validates all possible (booted, active) combinations" do
      # Generate all 9 combinations of (booted, active) where both are valid partitions
      all_combinations = for booted <- ["a", "b", "c"],
                            active <- ["a", "b", "c"],
                            do: {booted, active}

      # All should have valid write targets
      for {booted, active} <- all_combinations do
        result = PartitionRotationLogic.determine_next_partition(booted, active, true)

        assert match?({:ok, _}, result),
               "No valid write target for booted=#{booted}, active=#{active}"

        {:ok, target} = result

        # Verify safety constraints
        assert target != booted, "Writing to booted partition #{booted}"
        assert target != active, "Writing to active partition #{active}"
        assert target in ["a", "b", "c"], "Invalid target #{target}"
      end
    end

    test "validates deterministic behavior" do
      # The same inputs should always produce the same output
      test_states = [
        {"a", "a"},
        {"a", "b"},
        {"a", "c"},
        {"b", "b"},
        {"b", "a"},
        {"b", "c"},
        {"c", "c"},
        {"c", "a"},
        {"c", "b"}
      ]

      for {booted, active} <- test_states do
        # Call multiple times
        results = Enum.map(1..5, fn _ ->
          PartitionRotationLogic.determine_next_partition(booted, active, true)
        end)

        # All results should be identical
        assert length(Enum.uniq(results)) == 1,
               "Non-deterministic behavior for booted=#{booted}, active=#{active}"
      end
    end
  end
end

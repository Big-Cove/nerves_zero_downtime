defmodule NervesZeroDowntime.PartitionRotationLogic do
  @moduledoc """
  Pure logic module for determining 3-partition rotation.

  This module contains the core algorithm for rotating through partitions A, B, C
  in a hot-reload system. It's separated from runtime concerns to make it easy to test.

  ## The Algorithm

  Given three partitions (A, B, C) and two state variables:
  - `booted` - Partition where the kernel booted from (from /proc/cmdline, never changes)
  - `active` - Partition that will boot next (the boot pointer)

  The next write target is: **The ONE remaining partition** (not booted, not active)

  ## Key Rules

  1. Never write to `booted` partition (kernel lives there)
  2. Never write to `active` partition (that's the next boot target)
  3. Write to the remaining partition
  4. This creates automatic alternation between the two non-booted partitions

  ## Example Sequences

  Boot from A:
  - Initial: booted=a, active=a → write to b or c (choose b)
  - After step 1: booted=a, active=b → MUST write to c (only option)
  - After step 2: booted=a, active=c → MUST write to b (only option)
  - Pattern: b ↔ c (alternates automatically)

  Boot from B:
  - Initial: booted=b, active=b → write to a or c (choose a)
  - After step 1: booted=b, active=a → MUST write to c
  - After step 2: booted=b, active=c → MUST write to a
  - Pattern: a ↔ c (alternates automatically)
  """

  @type partition :: String.t()
  @type rotation_result :: {:ok, partition()} | {:error, term()}

  @doc """
  Determine which partition to write to next in a 3-partition rotation.

  ## Parameters
  - `booted` - The partition the kernel booted from (from /proc/cmdline)
  - `active` - The partition that will boot next (boot pointer)
  - `validated` - Whether the current firmware is validated

  ## Returns
  - `{:ok, partition}` - The partition to write to next
  - `{:error, reason}` - If the state is invalid

  ## Examples

      # Initial boot from A
      iex> PartitionRotationLogic.determine_next_partition("a", "a", true)
      {:ok, "b"}

      # After writing to B (now active=b, but still booted from a)
      iex> PartitionRotationLogic.determine_next_partition("a", "b", true)
      {:ok, "c"}

      # After writing to C (now active=c, but still booted from a)
      iex> PartitionRotationLogic.determine_next_partition("a", "c", true)
      {:ok, "b"}

      # Boot from B, initial state
      iex> PartitionRotationLogic.determine_next_partition("b", "b", true)
      {:ok, "a"}

      # After writing to A (now active=a, but still booted from b)
      iex> PartitionRotationLogic.determine_next_partition("b", "a", true)
      {:ok, "c"}
  """
  @spec determine_next_partition(partition(), partition(), boolean()) :: rotation_result()
  def determine_next_partition(booted, active, validated)

  # Validated firmware - determine available partition
  def determine_next_partition(booted, active, true)
      when booted in ["a", "b", "c"] and active in ["a", "b", "c"] do

    # Available partitions = all partitions - {booted, active}
    available = all_partitions() -- [booted, active]

    case available do
      [single] ->
        # Exactly one option (the normal case after first update)
        {:ok, single}

      [opt1, _opt2] ->
        # Two options (only happens when booted == active on initial boot)
        # Choose the first alphabetically for consistency
        {:ok, opt1}

      [] ->
        # Should never happen - means all partitions are blocked
        {:error, {:no_available_partition, "booted=#{booted}, active=#{active}"}}
    end
  end

  # Error cases
  def determine_next_partition(_booted, _active, false) do
    {:error, :firmware_not_validated}
  end

  def determine_next_partition(booted, active, validated) do
    {:error, {:invalid_parameters, "booted=#{inspect(booted)}, active=#{inspect(active)}, validated=#{inspect(validated)}"}}
  end

  @doc """
  Calculate which partitions are available for writing.

  Returns the partitions that are neither booted nor active.

  ## Examples

      iex> PartitionRotationLogic.available_partitions_for_write("a", "a")
      ["b", "c"]

      iex> PartitionRotationLogic.available_partitions_for_write("a", "b")
      ["c"]

      iex> PartitionRotationLogic.available_partitions_for_write("b", "c")
      ["a"]
  """
  @spec available_partitions_for_write(partition(), partition()) :: [partition()]
  def available_partitions_for_write(booted, active) do
    all_partitions() -- [booted, active]
  end

  @doc """
  Get all partitions in the system.
  """
  @spec all_partitions() :: [partition()]
  def all_partitions, do: ["a", "b", "c"]


  @doc """
  Validate that a partition identifier is valid.

  ## Examples

      iex> PartitionRotationLogic.valid_partition?("a")
      true

      iex> PartitionRotationLogic.valid_partition?("x")
      false
  """
  @spec valid_partition?(any()) :: boolean()
  def valid_partition?(partition), do: partition in all_partitions()

  @doc """
  Simulate an upgrade sequence starting from a booted partition.

  Returns the sequence of active partition values after each upgrade.

  ## Examples

      # Boot from A, do 4 upgrades
      iex> PartitionRotationLogic.simulate_sequence("a", 4)
      ["a", "b", "c", "b", "c"]

      # Boot from B, do 4 upgrades
      iex> PartitionRotationLogic.simulate_sequence("b", 4)
      ["b", "a", "c", "a", "c"]
  """
  @spec simulate_sequence(partition(), non_neg_integer()) :: [partition()]
  def simulate_sequence(booted, num_upgrades) when booted in ["a", "b", "c"] and num_upgrades >= 0 do
    Enum.reduce(1..num_upgrades, [booted], fn _, acc ->
      active = List.last(acc)
      {:ok, next} = determine_next_partition(booted, active, true)
      acc ++ [next]
    end)
  end
end

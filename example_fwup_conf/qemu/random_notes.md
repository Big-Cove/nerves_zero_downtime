Current boot A: Upgrading on B, C, B, C
Current boot A: Upgrading on C, B, C, B
Current boot B: Upgrading on A, C, A, C
Current boot B: Upgrading on C, A, C, A
Current boot C: Upgrading on A, B, A, B
Current boot C: Upgrading on B, A, B, A

| Step | Action            | nerves_fw_active | nerves_fw_booted | Notes                                                       |
  |------|-------------------|------------------|------------------|-------------------------------------------------------------|
  | 1    | Boot device       | a                | a                | Initial boot                                                |
  | 2    | Hot reload update | b                | a                | Wrote to B, hot reloaded code from B, but kernel still in A |
  | 3    | Hot reload update | c                | a                | Wrote to C, hot reloaded code from C, but kernel still in A |
  | 4    | Hot reload update | b                | a                | Wrote to B, hot reloaded code from B, but kernel still in A |
  | ...  | Continue          | b↔c              | a                | Pattern continues, alternating B and C                      |

  Boot from B (after physical reboot to B)

  | Step | Action            | nerves_fw_active | nerves_fw_booted | Notes                     |
  |------|-------------------|------------------|------------------|---------------------------|
  | 1    | Boot device       | b                | b                | Booted from B             |
  | 2    | Hot reload update | a or c           | b                | Can write to A or C       |
  | 3    | Hot reload update | c or a           | b                | Alternate between A and C |
  | ...  | Continue          | a↔c              | b                | Pattern continues         |

  Boot from C (after physical reboot to C)

  | Step | Action            | nerves_fw_active | nerves_fw_booted | Notes                     |
  |------|-------------------|------------------|------------------|---------------------------|
  | 1    | Boot device       | c                | c                | Booted from C             |
  | 2    | Hot reload update | a or b           | c                | Can write to A or B       |
  | 3    | Hot reload update | b or a           | c                | Alternate between A and B |
  | ...  | Continue          | a↔b              | c                | Pattern continues         |

    The Rule

  Given:
  - nerves_fw_booted = partition where kernel booted from (from /proc/cmdline)
  - nerves_fw_active = partition that will boot next (the boot pointer)

  Next write target = The ONE remaining partition (not booted, not active)

  Examples

  Boot from A, current sequence B→C→B→C:

  | Step | nerves_fw_booted | nerves_fw_active | Available partitions    | MUST write to    |
  |------|------------------|------------------|-------------------------|------------------|
  | 1    | a                | a                | {a,b,c} - {a,a} = {b,c} | b or c           |
  | 2    | a                | b                | {a,b,c} - {a,b} = {c}   | c (only option!) |
  | 3    | a                | c                | {a,b,c} - {a,c} = {b}   | b (only option!) |
  | 4    | a                | b                | {a,b,c} - {a,b} = {c}   | c (only option!) |

  Boot from B, sequence A→C→A→C:

  | Step | nerves_fw_booted | nerves_fw_active | Available partitions    | MUST write to    |
  |------|------------------|------------------|-------------------------|------------------|
  | 1    | b                | b                | {a,b,c} - {b,b} = {a,c} | a or c           |
  | 2    | b                | a                | {a,b,c} - {b,a} = {c}   | c (only option!) |
  | 3    | b                | c                | {a,b,c} - {b,c} = {a}   | a (only option!) |
  | 4    | b                | a                | {a,b,c} - {b,a} = {c}   | c (only option!) |
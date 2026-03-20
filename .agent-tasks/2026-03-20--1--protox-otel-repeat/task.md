# Task: Address PR #30 review feedback for protox migration

## P1: nil measurement handling
- `extract_measurement` can return nil when the measurement key doesn't exist
- Currently, `convert_value(nil, :int)` returns `{:as_int, 0}` which corrupts metrics
- Fix: skip the metric write when value is nil

## P2: decode/1 return shape
- Old protobuf library's decode/1 returned struct directly
- New protox-generated decode/1 returns {:ok, struct}
- Fix: change decode/1 to return struct directly for API compatibility

## P3: Large generated file
- 10,739 lines in a single file with 36 modules
- Only 22 modules are actually used by the library
- 14 modules (4,020 lines, 37.4%) are unused
- Plan: remove unused modules to reduce file to ~6,700 lines

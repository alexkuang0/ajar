#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sw_vers
system_profiler SPHardwareDataType | sed -n '/Model Name:/p; /Model Identifier:/p; /Chip:/p'
# Inspect device rows, not whether hidutil output is nonempty (headers always exist).
for match in '{"VendorID":0x5ac,"ProductID":0x8104,"PrimaryUsagePage":32,"PrimaryUsage":138}' '{"VendorID":0x5ac,"PrimaryUsagePage":32}' '{"VendorID":0x5ac,"ProductID":0x8104}'; do
    hidutil list --matching "$match"
done
mkdir -p .build/module-cache
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" Scripts/probe.swift -o .build/hinge-probe
.build/hinge-probe

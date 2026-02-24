# Multiple Regions Example

Demonstrates managing multiple regional routing actors simultaneously.

## Features

- Load multiple regions (Singapore, Thailand, etc.)
- Separate actors for each region
- Matrix calculations
- Proper cleanup

## Setup

```bash
# Ensure tiles exist for multiple regions
data/valhalla_tiles/
├── singapore/
│   └── 2/
└── thailand/
    └── 2/
```

## Run

```bash
export VALHALLA_TILES_DIR=/path/to/tiles
./gradlew run
```

## Output

```
═══════════════════════════════════════════════════════════
  Valhalla Multiple Regions Example
═══════════════════════════════════════════════════════════

📁 Base tile directory: /path/to/tiles

🔍 Checking singapore tiles: /path/to/tiles/singapore
✅ singapore actor created successfully

🔍 Checking thailand tiles: /path/to/tiles/thailand
✅ thailand actor created successfully

═══════════════════════════════════════════════════════════
  Testing Routes in Different Regions
═══════════════════════════════════════════════════════════

🇸🇬 Singapore Routes:
─────────────────────────────────────────────────────────
  ✅ Marina Bay → Changi
     Response: 12543 chars
  ✅ CBD → Sentosa
     Response: 8921 chars
  ✅ Orchard → Jurong
     Response: 11234 chars

🇹🇭 Thailand Routes:
─────────────────────────────────────────────────────────
  ✅ Bangkok Center
     Response: 7654 chars

📊 Matrix Calculation (Singapore)
─────────────────────────────────────────────────────────
✅ Matrix calculated: 1 source → 3 targets
   Response length: 2341 characters

═══════════════════════════════════════════════════════════
  Cleanup
═══════════════════════════════════════════════════════════

✅ Closed singapore actor
✅ Closed thailand actor

═══════════════════════════════════════════════════════════
  Example completed!
  Processed 2 region(s)
═══════════════════════════════════════════════════════════
```

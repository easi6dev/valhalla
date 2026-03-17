# Region Configuration

This directory contains the unified region configuration for Valhalla routing.

## Configuration Files

- **regions.json** - Single source of truth for all region definitions

## Environment-Specific Configuration

### Tile Directory Configuration

The tile directory root can be configured via environment variables to support different deployment environments:

**Environment Variable**: `VALHALLA_TILE_DIR`
**System Property**: `-Dvalhalla.tile.dir`
**Default**: `data/valhalla_tiles`

### Examples

**Development (Local)**:
```bash
# No environment variable needed - uses default
# Tiles stored at: data/valhalla_tiles/singapore
./gradlew build
```

**Production**:
```bash
export VALHALLA_TILE_DIR=/var/valhalla/tiles
# Tiles stored at: /var/valhalla/tiles/singapore
java -jar valhalla-jni.jar
```

**Staging**:
```bash
export VALHALLA_TILE_DIR=/var/valhalla/tiles
# Tiles stored at: /var/valhalla/tiles/singapore
java -jar valhalla-jni.jar
```

**Using System Property**:
```bash
java -Dvalhalla.tile.dir=/custom/path/tiles -jar valhalla-jni.jar
```

## Region Configuration Structure

Each region in `regions.json` contains:

```json
{
  "regions": {
    "singapore": {
      "name": "Singapore",
      "enabled": true,
      "osm_source": "https://...",
      "bounds": { ... },
      "tile_dir": "singapore",  // Relative path appended to VALHALLA_TILE_DIR
      "default_costing": "auto",
      "supported_costings": [...],
      "costing_options": { ... },
      "timezone": "Asia/Singapore",
      "locale": "en-SG",
      "currency": "SGD"
    }
  }
}
```

### Key Fields

- **tile_dir**: Region subdirectory name (appended to `VALHALLA_TILE_DIR`)
- **enabled**: Set to `false` to disable a region without removing its configuration
- **osm_source**: OpenStreetMap data source URL
- **bounds**: Geographic bounds for the region
- **supported_costings**: Available routing profiles (auto, motorcycle, taxi, etc.)
- **costing_options**: Profile-specific parameters

## Adding New Regions

1. Edit `regions.json`
2. Add new region configuration under `regions`
3. Set `enabled: true` to activate
4. Place region tiles in `$VALHALLA_TILE_DIR/{tile_dir}/`

See [ADDING_REGIONS.md](../../src/bindings/java/docs/regions/ADDING_REGIONS.md) for detailed instructions.

## Enabling/Disabling Regions

To disable a region (e.g., for maintenance or testing):

```json
{
  "thailand": {
    "enabled": false,
    ...
  }
}
```

This is runtime-configurable - no code changes required.

## Migration from Environment-Specific Files

**Previously**: Separate files (`regions-dev.json`, `regions-prod.json`, `regions-staging.json`)
**Now**: Single `regions.json` + `VALHALLA_TILE_DIR` environment variable

**Benefits**:
- Single source of truth for region definitions
- Easier maintenance (update once, not three times)
- No config drift between environments
- Simpler deployment

**What Changed**:
- Tile directory paths now use environment variable: `$VALHALLA_TILE_DIR/{region_name}`
- No more environment detection logic (`VALHALLA_ENV`)
- All region definitions in one file

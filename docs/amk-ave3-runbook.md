# AMK Ave 3 realignment runbook (DHL-32612)

LTA realigns Ang Mo Kio Ave 3 at AMK Hub from 14 Nov 2026 to around May 2028. `modify_osm_for_sg.py` in tada-graphhopper-import (`scripts/`) and valhalla (`deploy/scripts/`) applies the change to the SG map when `AMK_REALIGNMENT=on`.

Goal: switch both engines on the same day, keeping the gap between them as short as possible.

## Rollout (14 Nov 2026)

1. Set `AMK_REALIGNMENT` to `on`:
   - GraphHopper: `.github/workflows/build-graphhopper-import.yml` (tada-graphhopper-import)
   - Valhalla: `deploy/config/pipeline.prod.conf` (valhalla)
2. **GraphHopper:** push to `dist`. The import build runs and makes new routing data. Routing doesn't change yet.
3. **Valhalla:** release so `dist-latest` has the change, then start the SG tile pipeline by hand (the prod SG cronjob is suspended). The new tiles go live when it finishes.
4. **Straight after step 3:** update `ROUTING_DATA_URL` in tada-routing-service to the data from step 2 and deploy. GraphHopper switches now. The only gap between the two engines is the time between steps 3 and 4.
5. **Check on both engines:** a car going east on Ave 3 now detours (about 3 km), cars leave the pick-up point by the new exit, the carpark exit turns right only, and buses still use Ave 3.

## Revert (~May 2028, when LTA restores the road)

Same steps with `AMK_REALIGNMENT` set to `off`, in the same order: Valhalla tiles first, then the GraphHopper data URL straight after. Then remove the script and the switch from both repos.

## If OSM maps the change itself before then

The script stops the build with an error, so the current routes keep working. Set `AMK_REALIGNMENT` to `off` in both repos and follow the same order. Valhalla will notice first, because it downloads new OSM every week; GraphHopper uses a fixed OSM copy.

## Note

The two scripts are not identical. The Valhalla copy also sets `motorcar=no` and `taxi=no` and stops the build if these roads already have access tags; GraphHopper doesn't need that. Any change to the road edits themselves must be made in both repos.

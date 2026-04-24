package global.tada.valhalla.traffic.mapping

import global.tada.valhalla.traffic.models.SpeedBandEntry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Unit tests for [GeometryMappingService], [GeometryMappingCache], and [MappingReportGenerator].
 *
 * Uses a mock locate function — no native library or tile data required.
 */
class GeometryMappingServiceTest {

    /**
     * Build a mock locate() response matching the real Valhalla verbose format.
     * Each edge is a map with keys: level, tile_id, id, distance, heading, classification, name
     */
    private fun mockLocateResponse(vararg locations: List<Map<String, Any>>): String {
        val arr = JSONArray()
        for (edges in locations) {
            val loc = JSONObject()
            val edgesArr = JSONArray()
            for (edge in edges) {
                val edgeJson = JSONObject()
                edgeJson.put("edge_id", JSONObject().apply {
                    put("level", edge["level"] ?: 2)
                    put("tile_id", edge["tile_id"] ?: 100)
                    put("id", edge["id"] ?: 0)
                })
                edgeJson.put("distance", edge["distance"] ?: 5.0)
                edgeJson.put("heading", edge["heading"] ?: 90.0)
                // Road names and way_id in edge_info (real Valhalla format)
                edgeJson.put("edge_info", JSONObject().apply {
                    val name = edge["name"] ?: ""
                    put("names", JSONArray().apply {
                        if ((name as String).isNotEmpty()) put(name)
                    })
                    put("way_id", edge["way_id"] ?: 0L)
                })
                // Road class in edge.classification.classification (real Valhalla format)
                edgeJson.put("edge", JSONObject().apply {
                    put("classification", JSONObject().apply {
                        put("classification", edge["road_class"] ?: "motorway")
                    })
                })
                edgesArr.put(edgeJson)
            }
            loc.put("edges", edgesArr)
            arr.put(loc)
        }
        return arr.toString()
    }

    private fun makeSpeedBand(
        linkId: String = "100001",
        roadName: String = "PIE",
        roadCategory: String = "1",
        startLat: Double = 1.3521,
        startLon: Double = 103.8198,
        endLat: Double = 1.3525,
        endLon: Double = 103.8210
    ) = SpeedBandEntry(
        linkId = linkId,
        roadName = roadName,
        roadCategory = roadCategory,
        speedBand = 6,
        minimumSpeed = 50,
        maximumSpeed = 60,
        startLat = startLat,
        startLon = startLon,
        endLat = endLat,
        endLon = endLon
    )

    // --- GeometryMappingService tests ---

    @Test
    fun `buildMapping with high confidence match`() {
        // Close distance, good bearing (roughly east ~83 deg), name match, category match
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(mapOf("level" to 2, "tile_id" to 756425, "id" to 10,
                    "distance" to 2.0, "heading" to 83.0, "road_class" to "motorway",
                    "name" to "PAN ISLAND EXPRESSWAY")),
                listOf(mapOf("level" to 2, "tile_id" to 756425, "id" to 11,
                    "distance" to 3.0, "heading" to 83.0, "road_class" to "motorway",
                    "name" to "PAN ISLAND EXPRESSWAY"))
            )
        }

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(listOf(makeSpeedBand()))

        assertEquals(1, mapping.summary.total)
        assertEquals(1, mapping.summary.mapped)
        assertEquals(0, mapping.summary.unmapped)

        val seg = mapping.segments["100001"]
        assertNotNull(seg)
        val best = seg.bestCandidate
        assertNotNull(best)
        assertEquals(ConfidenceLevel.HIGH, best.confidence)
        assertTrue(best.totalScore >= 0.75)
        assertTrue(best.roadNameMatch)
        assertTrue(best.categoryMatch)
    }

    @Test
    fun `buildMapping with no candidates returns unmapped`() {
        val locateFn: (String) -> String = {
            // Empty response — no edges
            JSONArray().apply {
                put(JSONObject()) // location with no edges array
                put(JSONObject())
            }.toString()
        }

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(listOf(makeSpeedBand()))

        assertEquals(1, mapping.summary.total)
        assertEquals(0, mapping.summary.mapped)
        assertEquals(1, mapping.summary.unmapped)

        val seg = mapping.segments["100001"]
        assertNotNull(seg)
        assertNull(seg.bestCandidate)
        assertTrue(seg.flagged)
    }

    @Test
    fun `buildMapping flags ambiguous candidates when best is not high confidence`() {
        // Two candidates with similar MEDIUM scores on a small road (category 5).
        // Moderate distance, partial bearing match, no name match — both land in MEDIUM range.
        // Ambiguity is only flagged when best candidate is NOT high confidence.
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(
                    mapOf("level" to 2, "tile_id" to 100, "id" to 1,
                        "distance" to 15.0, "heading" to 83.0, "road_class" to "residential",
                        "name" to "SOME ROAD"),
                    mapOf("level" to 2, "tile_id" to 100, "id" to 2,
                        "distance" to 16.0, "heading" to 83.0, "road_class" to "residential",
                        "name" to "SOME ROAD")
                ),
                listOf()
            )
        }

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(listOf(makeSpeedBand(roadCategory = "5", roadName = "OTHER ROAD")))

        val seg = mapping.segments["100001"]
        assertNotNull(seg)
        assertTrue(seg.flagged, "Should be flagged as ambiguous when best is not HIGH")
        assertTrue(seg.flagReason.contains("ambiguous"))
        assertEquals(2, seg.allCandidates.size)
    }

    @Test
    fun `buildMapping does not flag ambiguous when best is high confidence`() {
        // Two HIGH-confidence candidates on an expressway — should NOT be flagged
        // because we trust the best when it's HIGH confidence.
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(
                    mapOf("level" to 2, "tile_id" to 100, "id" to 1,
                        "distance" to 3.0, "heading" to 83.0, "road_class" to "motorway",
                        "name" to "PAN ISLAND EXPRESSWAY"),
                    mapOf("level" to 2, "tile_id" to 100, "id" to 2,
                        "distance" to 3.5, "heading" to 83.0, "road_class" to "motorway",
                        "name" to "PAN ISLAND EXPRESSWAY")
                ),
                listOf()
            )
        }

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(listOf(makeSpeedBand()))

        val seg = mapping.segments["100001"]
        assertNotNull(seg)
        assertTrue(!seg.flagged, "Should NOT be flagged when best is HIGH confidence")
        assertEquals(ConfidenceLevel.HIGH, seg.bestCandidate?.confidence)
        assertEquals(2, seg.allCandidates.size)
    }

    @Test
    fun `buildMapping with low confidence distant edge`() {
        // Far distance, wrong bearing, no name match, wrong category
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(mapOf("level" to 2, "tile_id" to 200, "id" to 5,
                    "distance" to 30.0, "heading" to 270.0, "road_class" to "residential",
                    "name" to "SOME OTHER ROAD")),
                listOf()
            )
        }

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(listOf(makeSpeedBand()))

        val seg = mapping.segments["100001"]
        assertNotNull(seg)
        val best = seg.bestCandidate
        assertNotNull(best)
        assertTrue(best.confidence == ConfidenceLevel.LOW || best.confidence == ConfidenceLevel.NONE,
            "Should be LOW or NONE confidence for distant/mismatched edge")
    }

    @Test
    fun `buildMapping selects best of multiple candidates`() {
        // Good candidate and bad candidate — should pick the good one
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(
                    mapOf("level" to 2, "tile_id" to 100, "id" to 1,
                        "distance" to 30.0, "heading" to 270.0, "road_class" to "residential",
                        "name" to "WRONG ROAD"),
                    mapOf("level" to 2, "tile_id" to 100, "id" to 2,
                        "distance" to 2.0, "heading" to 83.0, "road_class" to "motorway",
                        "name" to "PAN ISLAND EXPRESSWAY")
                ),
                listOf()
            )
        }

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(listOf(makeSpeedBand()))

        val seg = mapping.segments["100001"]
        assertNotNull(seg)
        assertEquals(2, seg.bestCandidate?.edge?.edgeIndex, "Should select the better candidate (edgeIndex=2)")
        assertEquals(ConfidenceLevel.HIGH, seg.bestCandidate?.confidence)
    }

    @Test
    fun `buildMapping with multiple segments`() {
        var callCount = 0
        val locateFn: (String) -> String = {
            callCount++
            mockLocateResponse(
                listOf(mapOf("level" to 2, "tile_id" to 100, "id" to callCount,
                    "distance" to 3.0, "heading" to 83.0, "road_class" to "motorway",
                    "name" to "PIE")),
                listOf()
            )
        }

        val bands = listOf(
            makeSpeedBand(linkId = "1001", roadName = "PIE"),
            makeSpeedBand(linkId = "1002", roadName = "PIE"),
            makeSpeedBand(linkId = "1003", roadName = "PIE")
        )

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(bands)

        assertEquals(3, mapping.summary.total)
        assertEquals(3, mapping.summary.mapped)
        assertEquals(0, mapping.summary.unmapped)
        assertEquals(3, callCount)
    }

    @Test
    fun `buildMapping handles locate exception gracefully`() {
        val locateFn: (String) -> String = {
            throw RuntimeException("Simulated native error")
        }

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(listOf(makeSpeedBand()))

        assertEquals(1, mapping.summary.total)
        assertEquals(0, mapping.summary.mapped)
        assertEquals(1, mapping.summary.unmapped)

        val seg = mapping.segments["100001"]
        assertNotNull(seg)
        assertTrue(seg.flagged)
        assertTrue(seg.flagReason.contains("locate() error"))
    }

    @Test
    fun `summary byCategory is populated`() {
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(mapOf("level" to 2, "tile_id" to 100, "id" to 1,
                    "distance" to 2.0, "heading" to 83.0, "road_class" to "motorway",
                    "name" to "PIE")),
                listOf()
            )
        }

        val bands = listOf(
            makeSpeedBand(linkId = "1", roadCategory = "1"),
            makeSpeedBand(linkId = "2", roadCategory = "2"),
            makeSpeedBand(linkId = "3", roadCategory = "1")
        )

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(bands)

        assertEquals(2, mapping.summary.byCategory.size)
        assertEquals(2, mapping.summary.byCategory["1"]?.total)
        assertEquals(1, mapping.summary.byCategory["2"]?.total)
        assertEquals("Expressway", mapping.summary.byCategory["1"]?.categoryName)
    }

    // --- GeometryMappingCache tests ---

    @Test
    fun `cache save and load roundtrip`() {
        val seg = MappedSegment(
            linkId = "100001",
            roadName = "PIE",
            roadCategory = "1",
            bestCandidate = ScoredCandidate(
                edge = MappedEdge(2, 756425, 347),
                totalScore = 0.92,
                confidence = ConfidenceLevel.HIGH,
                distanceM = 3.2,
                bearingDiffDeg = 5.1,
                roadNameMatch = true,
                categoryMatch = true,
                osmRoadName = "PAN ISLAND EXPRESSWAY",
                osmRoadClass = "motorway",
                osmWayId = 12345L
            ),
            allCandidates = listOf(ScoredCandidate(
                edge = MappedEdge(2, 756425, 347),
                totalScore = 0.92,
                confidence = ConfidenceLevel.HIGH,
                distanceM = 3.2,
                bearingDiffDeg = 5.1,
                roadNameMatch = true,
                categoryMatch = true,
                osmRoadName = "PAN ISLAND EXPRESSWAY",
                osmRoadClass = "motorway",
                osmWayId = 12345L
            )),
            flagged = false,
            flagReason = ""
        )

        val mapping = GeometryMapping(
            segments = mapOf("100001" to seg),
            tileToEdges = mapOf(TileKey(2, 756425) to setOf(347)),
            summary = MappingSummary(
                total = 1, mapped = 1, unmapped = 0,
                highConfidence = 1, mediumConfidence = 0, lowConfidence = 0,
                flagged = 0, byCategory = emptyMap()
            )
        )

        val tmpFile = java.io.File.createTempFile("geo_mapping_test", ".json")
        tmpFile.deleteOnExit()

        GeometryMappingCache.save(mapping, tmpFile.absolutePath)
        val loaded = GeometryMappingCache.load(tmpFile.absolutePath)

        assertNotNull(loaded)
        assertEquals(1, loaded.summary.total)
        assertEquals(1, loaded.summary.mapped)
        assertEquals(1, loaded.summary.highConfidence)
        assertNotNull(loaded.segments["100001"])
        assertEquals(0.92, loaded.segments["100001"]!!.bestCandidate!!.totalScore, 0.001)
        assertEquals(ConfidenceLevel.HIGH, loaded.segments["100001"]!!.bestCandidate!!.confidence)
        assertTrue(loaded.tileToEdges.containsKey(TileKey(2, 756425)))
    }

    @Test
    fun `cache load returns null for missing file`() {
        val loaded = GeometryMappingCache.load("/tmp/nonexistent_geo_mapping_test_file.json")
        assertNull(loaded)
    }

    @Test
    fun `cache load returns null for wrong version`() {
        val tmpFile = java.io.File.createTempFile("geo_mapping_v99", ".json")
        tmpFile.deleteOnExit()
        tmpFile.writeText("""{"version": 99, "mappings": []}""")

        val loaded = GeometryMappingCache.load(tmpFile.absolutePath)
        assertNull(loaded)
    }

    @Test
    fun `toLegacyEdgeMapping converts correctly`() {
        val seg = MappedSegment(
            linkId = "100001",
            roadName = "PIE",
            roadCategory = "1",
            bestCandidate = ScoredCandidate(
                edge = MappedEdge(2, 756425, 347),
                totalScore = 0.92, confidence = ConfidenceLevel.HIGH,
                distanceM = 3.2, bearingDiffDeg = 5.1,
                roadNameMatch = true, categoryMatch = true,
                osmRoadName = "", osmRoadClass = "", osmWayId = 0L
            ),
            allCandidates = emptyList(),
            flagged = false,
            flagReason = ""
        )
        val unmappedSeg = MappedSegment(
            linkId = "100002",
            roadName = "UNKNOWN",
            roadCategory = "5",
            bestCandidate = null,
            allCandidates = emptyList(),
            flagged = true,
            flagReason = "no candidates"
        )

        val mapping = GeometryMapping(
            segments = mapOf("100001" to seg, "100002" to unmappedSeg),
            tileToEdges = mapOf(TileKey(2, 756425) to setOf(347)),
            summary = MappingSummary(
                total = 2, mapped = 1, unmapped = 1,
                highConfidence = 1, mediumConfidence = 0, lowConfidence = 0,
                flagged = 1, byCategory = emptyMap()
            )
        )

        val legacy = GeometryMappingCache.toLegacyEdgeMapping(mapping)

        assertEquals(1, legacy.totalMapped)
        assertEquals(1, legacy.totalUnmapped)
        assertNotNull(legacy.linkToEdges["100001"])
        assertEquals(MappedEdge(2, 756425, 347), legacy.linkToEdges["100001"]!![0])
        assertNull(legacy.linkToEdges["100002"])
    }

    // --- MappingReportGenerator tests ---

    @Test
    fun `report generation produces valid report`() {
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(mapOf("level" to 2, "tile_id" to 100, "id" to 1,
                    "distance" to 2.0, "heading" to 83.0, "road_class" to "motorway",
                    "name" to "PIE")),
                listOf()
            )
        }

        val bands = listOf(
            makeSpeedBand(linkId = "1", roadCategory = "1"),
            makeSpeedBand(linkId = "2", roadCategory = "1")
        )

        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(bands)
        val report = MappingReportGenerator.generateReport(mapping, bands)

        assertEquals(2, report.overall.total)
        assertEquals(2, report.overall.mapped)
        assertTrue(report.overall.highConfidencePercent > 0)
        assertNotNull(report.generatedAt)
    }

    @Test
    fun `text report writes to file`() {
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(mapOf("level" to 2, "tile_id" to 100, "id" to 1,
                    "distance" to 2.0, "heading" to 83.0, "road_class" to "motorway",
                    "name" to "PIE")),
                listOf()
            )
        }

        val bands = listOf(makeSpeedBand())
        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(bands)
        val report = MappingReportGenerator.generateReport(mapping, bands)

        val tmpFile = java.io.File.createTempFile("geo_report_test", ".txt")
        tmpFile.deleteOnExit()

        MappingReportGenerator.writeTextReport(report, tmpFile.absolutePath)

        val content = tmpFile.readText()
        assertTrue(content.contains("LTA -> OSM Geometry Mapping Report"))
        assertTrue(content.contains("OVERALL:"))
        assertTrue(content.contains("ACCEPTANCE CRITERIA:"))
    }

    @Test
    fun `json report writes valid JSON to file`() {
        val locateFn: (String) -> String = {
            mockLocateResponse(
                listOf(mapOf("level" to 2, "tile_id" to 100, "id" to 1,
                    "distance" to 2.0, "heading" to 83.0, "road_class" to "motorway",
                    "name" to "PIE")),
                listOf()
            )
        }

        val bands = listOf(makeSpeedBand())
        val service = GeometryMappingService(locateFn)
        val mapping = service.buildMapping(bands)
        val report = MappingReportGenerator.generateReport(mapping, bands)

        val tmpFile = java.io.File.createTempFile("geo_report_test", ".json")
        tmpFile.deleteOnExit()

        MappingReportGenerator.writeJsonReport(report, tmpFile.absolutePath)

        val json = org.json.JSONObject(tmpFile.readText())
        assertTrue(json.has("overall"))
        assertTrue(json.has("acceptanceCriteriaMet"))
        assertTrue(json.has("flaggedSegments"))
        assertTrue(json.has("unmappedSegments"))
    }
}

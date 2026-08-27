import XCTest
import simd
@testable import wisescan_ios

/// `RoomPlanCategory` — the rich, unconsolidated RoomPlan label vocabulary that `roomplan.json` has
/// always stored, and the derived palette / legend-filter helpers that let the mesh preview show it.
///
/// Everything under test here is a pure function of an enum case, so it is exactly the part of the
/// feature that can be checked without a device: the rendering, the gestures and the SceneKit node
/// walk cannot be. What these tests defend is the set of properties the design leans on and that a
/// later edit could quietly break:
///
///   * the vocabulary matches what the exporter actually writes (a typo'd raw value would make a
///     whole category silently unlabelled — it would parse to nil and simply never show up);
///   * the rich mapping and the two existing string mappers agree, since they are stated separately;
///   * index 0 of every coarse group returns the base colour byte for byte, which is what keeps the
///     user guide's static legend and the existing colour language true;
///   * shades within a group are distinct, which is the only thing that makes the derivation worth
///     doing at all;
///   * the filter predicate keys off the ACTIVE vocabulary, which is why the filter is cleared when
///     the vocabulary flips.
final class SemanticLabelDetailTests: XCTestCase {

    /// Exactly the strings `RoomPlanExporter.categoryString` writes for surfaces.
    private let surfaceStrings = ["wall", "floor", "door", "window", "opening"]
    /// Exactly the strings `RoomPlanExporter.objectCategoryString` writes for objects.
    private let objectStrings = ["table", "chair", "sofa", "bed", "storage", "refrigerator",
                                 "stove", "sink", "washer_dryer", "dishwasher", "oven",
                                 "fireplace", "television", "bathtub", "toilet", "stairs"]

    private var allStrings: [String] { surfaceStrings + objectStrings }

    // MARK: - Vocabulary

    /// 5 surfaces + 16 objects, and nothing else. A category added to the enum without being added
    /// to the exporter (or vice versa) is a label that can never appear on screen.
    func testVocabularyIsExactlyWhatTheExporterWrites() {
        XCTAssertEqual(allStrings.count, 21)
        XCTAssertEqual(Set(RoomPlanCategory.allCases.map(\.rawValue)), Set(allStrings))
    }

    /// Every stored string round-trips to a case, a non-empty display name, and a colour — the
    /// contract the loader and the legend both rely on.
    func testEveryStoredStringResolvesToANameAndAColour() {
        for raw in allStrings {
            guard let category = RoomPlanCategory(rawValue: raw) else {
                return XCTFail("\(raw) does not parse as a RoomPlanCategory")
            }
            XCTAssertFalse(category.displayName.isEmpty, raw)
            XCTAssertFalse(category.displayName.contains("_"), "\(raw) leaks its raw spelling")
            XCTAssertEqual(RoomPlanCategory.displayName(forCategory: raw), category.displayName)
            XCTAssertEqual(category.fullDetailColor.w, 1, "\(raw) lost its alpha")
        }
    }

    /// The one raw value that is NOT a spelling of a real category: the exporter's own fallback for
    /// a RoomPlan category newer than the app. It has to answer with something rather than trap, and
    /// the colour it answers with has to be the one the renderer already treats as "don't draw".
    func testUnknownCategoryStillAnswers() {
        XCTAssertNil(RoomPlanCategory(rawValue: "unknown"))
        XCTAssertEqual(RoomPlanCategory.displayName(forCategory: "unknown"), "Unknown")
        for detail in SemanticLabelDetail.allCases {
            XCTAssertEqual(RoomPlanCategory.color(forCategory: "unknown", detail: detail),
                           SemanticClass.none.color)
        }
    }

    /// The name the whole feature exists to show, and the only one that is not just a capitalisation.
    func testWasherDryerReadsAsAName() {
        XCTAssertEqual(RoomPlanCategory.washerDryer.displayName, "Washer / Dryer")
        XCTAssertEqual(RoomPlanCategory.displayName(forCategory: "washer_dryer"), "Washer / Dryer")
    }

    // MARK: - Agreement with the existing consolidation

    /// `coarseClass` states the consolidation a second time rather than calling the two existing
    /// string mappers (which are domain-scoped: to them a SURFACE called "table" is `.none`). This
    /// is the test that stops the two statements from drifting.
    func testCoarseClassAgreesWithTheExistingStringMappers() {
        for raw in surfaceStrings {
            XCTAssertEqual(RoomPlanCategory(rawValue: raw)?.coarseClass,
                           SemanticClass.fromSurfaceCategory(raw), raw)
        }
        for raw in objectStrings {
            XCTAssertEqual(RoomPlanCategory(rawValue: raw)?.coarseClass,
                           SemanticClass.fromObjectCategory(raw), raw)
        }
    }

    /// No category consolidates into `.none` — `buildRoomPlanOutlines` skips `.none`, so one that
    /// did would be a category that parses and then never draws.
    func testNoCategoryConsolidatesIntoNone() {
        for category in RoomPlanCategory.allCases {
            XCTAssertNotEqual(category.coarseClass, .none, category.rawValue)
        }
    }

    /// RoomPlan has no ceiling category at all — which is exactly what the user guide's dimmed
    /// "Not yet supported by RoomPlan" row says, and why the full set is 21 rather than 22.
    func testCeilingHasNoRichCategories() {
        XCTAssertTrue(RoomPlanCategory.categories(in: .ceiling).isEmpty)
    }

    /// `.fixture` is the group the derivation has to survive: 12 categories on one base colour.
    func testFixtureAbsorbsTwelveCategories() {
        XCTAssertEqual(RoomPlanCategory.categories(in: .fixture).count, 12)
    }

    /// Every category belongs to exactly one group, and the groups partition the vocabulary.
    func testGroupsPartitionTheVocabulary() {
        let grouped = SemanticClass.allCases.flatMap { RoomPlanCategory.categories(in: $0) }
        XCTAssertEqual(grouped.count, RoomPlanCategory.allCases.count)
        XCTAssertEqual(Set(grouped), Set(RoomPlanCategory.allCases))
    }

    // MARK: - Derived palette

    /// The anchor rule: the first category in a coarse group keeps that class's colour EXACTLY, so a
    /// single-member group (wall, floor, table, window) renders identically at either detail and the
    /// existing colour language survives.
    func testFirstCategoryInEachGroupKeepsTheBaseColourExactly() {
        for cls in SemanticClass.allCases where cls != .none {
            guard let first = RoomPlanCategory.categories(in: cls).first else { continue }
            XCTAssertEqual(first.fullDetailColor, cls.color, "\(cls.rawValue) lost its anchor")
        }
    }

    /// Index 0 and a group with nothing to separate both return the base untouched.
    func testDerivedShadeIsIdentityAtIndexZeroAndForSingletonGroups() {
        let base = SIMD4<Float>(0.7, 0.3, 0.9, 1)
        XCTAssertEqual(RoomPlanCategory.derivedShade(base: base, index: 0, groupCount: 12), base)
        XCTAssertEqual(RoomPlanCategory.derivedShade(base: base, index: 3, groupCount: 1), base)
    }

    /// Coarse detail is never derived: it is the group's base colour, whatever the category.
    func testCoarseDetailAlwaysReturnsTheGroupBaseColour() {
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(RoomPlanCategory.color(forCategory: category.rawValue, detail: .coarse),
                           category.coarseClass.color, category.rawValue)
        }
    }

    /// Full detail is the derived shade, routed through the same raw-string entry point the renderer
    /// uses (the node only ever holds the string).
    func testFullDetailRoutesToTheDerivedShade() {
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(RoomPlanCategory.color(forCategory: category.rawValue, detail: .full),
                           category.fullDetailColor, category.rawValue)
        }
    }

    /// Pure function, no randomness, no state: the same category must always give the same shade,
    /// and repeated evaluation must not drift.
    func testDerivationIsDeterministic() {
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(category.fullDetailColor, category.fullDetailColor, category.rawValue)
        }
        let base = SIMD4<Float>(0.7, 0.3, 0.9, 1)
        for index in 0..<12 {
            let first = RoomPlanCategory.derivedShade(base: base, index: index, groupCount: 12)
            for _ in 0..<3 {
                XCTAssertEqual(RoomPlanCategory.derivedShade(base: base, index: index, groupCount: 12),
                               first, "index \(index)")
            }
        }
    }

    /// The point of the ramp: two categories in the same coarse group never render in the same
    /// colour. Checked pairwise, per group — `.fixture`'s 12 members are the real case.
    func testShadesWithinACoarseGroupArePairwiseDistinct() {
        for cls in SemanticClass.allCases where cls != .none {
            let group = RoomPlanCategory.categories(in: cls)
            for (i, a) in group.enumerated() {
                for b in group[(i + 1)...] {
                    XCTAssertNotEqual(a.fullDetailColor, b.fullDetailColor,
                                      "\(a.rawValue) and \(b.rawValue) collide in \(cls.rawValue)")
                }
            }
        }
    }

    /// A shade has to be a colour SceneKit can use: components in 0…1, alpha carried through from
    /// the base. A clamp bug here would show up as a black or blown-out box, not as a wrong hue.
    func testEveryShadeIsAValidColour() {
        for category in RoomPlanCategory.allCases {
            let c = category.fullDetailColor
            for (name, component) in [("r", c.x), ("g", c.y), ("b", c.z), ("a", c.w)] {
                XCTAssertGreaterThanOrEqual(component, 0, "\(category.rawValue).\(name)")
                XCTAssertLessThanOrEqual(component, 1, "\(category.rawValue).\(name)")
            }
        }
    }

    /// The hue window widens with group size instead of the step being fixed — that is what stops a
    /// 12-way split from collapsing into invisible increments — but stays capped, so no group
    /// wanders into a neighbouring class's hue.
    func testHueWindowGrowsWithGroupSizeAndStaysCapped() {
        XCTAssertLessThan(RoomPlanCategory.fullDetailBaseHueSpan,
                          RoomPlanCategory.fullDetailMaxHueSpan)
        XCTAssertGreaterThan(RoomPlanCategory.fullDetailHueSpanGrowth, 0)
        // Two members use the base window; twelve are capped rather than spread over a third of the
        // colour wheel.
        let twoSpan = RoomPlanCategory.fullDetailBaseHueSpan
        let twelveSpan = min(RoomPlanCategory.fullDetailMaxHueSpan,
                            RoomPlanCategory.fullDetailBaseHueSpan
                                + RoomPlanCategory.fullDetailHueSpanGrowth * 10)
        XCTAssertGreaterThan(twelveSpan, twoSpan)
        XCTAssertEqual(twelveSpan, RoomPlanCategory.fullDetailMaxHueSpan, accuracy: 1e-6)
    }

    // MARK: - Legend rows and the filter predicate

    /// The legend key IS the row identity, so it has to follow the active vocabulary: at full detail
    /// a sofa is its own row, at coarse detail it is part of "seat".
    func testLegendKeyFollowsTheActiveVocabulary() {
        XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: "sofa", detail: .full), "sofa")
        XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: "sofa", detail: .coarse), "seat")
        XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: "opening", detail: .full), "opening")
        XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: "opening", detail: .coarse), "door")
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: category.rawValue, detail: .full),
                           category.rawValue)
            XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: category.rawValue, detail: .coarse),
                           category.coarseClass.rawValue)
        }
    }

    /// Nothing is filtered by an empty selection — the default state must draw everything.
    func testEmptySelectionHidesNothing() {
        for detail in SemanticLabelDetail.allCases {
            for category in RoomPlanCategory.allCases {
                XCTAssertTrue(RoomPlanCategory.isVisible(category: category.rawValue,
                                                         detail: detail, hiddenLabels: []),
                              category.rawValue)
            }
        }
    }

    /// A coarse row filters its whole group and nothing else — hiding "seat" takes the chairs, sofas
    /// and beds with it, and leaves the tables alone.
    func testCoarseRowFiltersItsWholeGroup() {
        let hidden: Set<String> = ["seat"]
        for category in RoomPlanCategory.allCases {
            let expected = category.coarseClass != .seat
            XCTAssertEqual(RoomPlanCategory.isVisible(category: category.rawValue,
                                                      detail: .coarse, hiddenLabels: hidden),
                           expected, category.rawValue)
        }
    }

    /// A full-detail row filters exactly one category — the sofa goes, the chair and the bed stay.
    /// This is the difference the two vocabularies make to the same tap.
    func testFullDetailRowFiltersExactlyOneCategory() {
        let hidden: Set<String> = ["sofa"]
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(RoomPlanCategory.isVisible(category: category.rawValue,
                                                      detail: .full, hiddenLabels: hidden),
                           category != .sofa, category.rawValue)
        }
    }

    /// The two vocabularies spell five categories identically, so a selection kept across a detail
    /// flip would filter the wrong rows — silently, because it would not even look wrong. This
    /// pins the overlap that makes clearing the filter on the flip mandatory rather than tidy.
    func testTheTwoVocabulariesOverlapWhichIsWhyTheFilterIsCleared() {
        let coarseKeys = Set(SemanticClass.allCases.map(\.rawValue))
        let fullKeys = Set(RoomPlanCategory.allCases.map(\.rawValue))
        XCTAssertEqual(coarseKeys.intersection(fullKeys),
                       ["wall", "floor", "door", "window", "table"])
        // "seat" is a coarse row only; "sofa" is a full row only. Each is inert in the other mode,
        // which is the harmless half of the same overlap.
        XCTAssertTrue(RoomPlanCategory.isVisible(category: "sofa", detail: .full,
                                                 hiddenLabels: ["seat"]))
        XCTAssertTrue(RoomPlanCategory.isVisible(category: "sofa", detail: .coarse,
                                                 hiddenLabels: ["sofa"]))
        // …and "table" is the harmful half: the same key means a different row in each vocabulary.
        XCTAssertFalse(RoomPlanCategory.isVisible(category: "table", detail: .full,
                                                  hiddenLabels: ["table"]))
        XCTAssertFalse(RoomPlanCategory.isVisible(category: "table", detail: .coarse,
                                                  hiddenLabels: ["table"]))
    }

    /// A label the filter cannot name is never hidden by it: an unparseable category (and an unnamed
    /// node) has no legend row, so the filter has nothing to say about it. Without this, an unknown
    /// category could be hidden with no row to bring it back.
    func testUnnameableLabelsAreNeverFiltered() {
        for detail in SemanticLabelDetail.allCases {
            XCTAssertNil(RoomPlanCategory.legendKey(forCategory: "unknown", detail: detail))
            XCTAssertNil(RoomPlanCategory.legendKey(forCategory: nil, detail: detail))
            XCTAssertTrue(RoomPlanCategory.isVisible(category: "unknown", detail: detail,
                                                     hiddenLabels: ["unknown", "wall", "sofa"]))
            XCTAssertTrue(RoomPlanCategory.isVisible(category: nil, detail: detail,
                                                     hiddenLabels: ["unknown", "wall", "sofa"]))
        }
    }

    // MARK: - The detail toggle itself

    /// Two states, and `next` is an involution — the button always returns you to where you were.
    func testDetailToggleIsATwoStateFlip() {
        XCTAssertEqual(SemanticLabelDetail.allCases.count, 2)
        XCTAssertEqual(SemanticLabelDetail.coarse.next, .full)
        XCTAssertEqual(SemanticLabelDetail.full.next, .coarse)
        for detail in SemanticLabelDetail.allCases {
            XCTAssertEqual(detail.next.next, detail)
            XCTAssertFalse(detail.iconName.isEmpty)
            XCTAssertFalse(detail.accessibilityLabel.isEmpty)
        }
    }

    /// The persisted default has to parse back, or every preview would silently fall back to coarse
    /// and the persistence would look broken rather than absent.
    func testPersistedDefaultParses() {
        XCTAssertEqual(SemanticLabelDetail(rawValue: AppConstants.semanticLabelDetail), .coarse)
    }
}

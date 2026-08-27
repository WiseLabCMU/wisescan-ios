import XCTest
import simd
import SceneKit
import UIKit
@testable import wisescan_ios

/// `RoomPlanCategory` — the rich, unconsolidated RoomPlan label vocabulary that `roomplan.json` has
/// always stored, and the derived palette / legend-filter helpers that let the mesh preview show it.
///
/// Most of what is under test here is a pure function of an enum case. Two more things are checked
/// because they turn out not to need a device either: `semanticLabelOwner` is a plain `SCNNode`
/// walk, and `styleSemanticNode` is two property writes on an `SCNMaterial` — neither renders
/// anything. What genuinely cannot be checked here is the drawing itself, the gesture
/// deconfliction and `SCNView.hitTest`, which needs a live renderer.
///
/// What these tests defend is the set of properties the design leans on and that a later edit could
/// quietly break:
///
///   * the vocabulary matches a hand-transcription of what the exporter writes — the mappers are
///     `private`, so this pins the enum, not the exporter (a typo'd raw value would make a whole
///     category silently unlabelled: it would parse to nil and simply never show up);
///   * the rich mapping and the two existing string mappers agree, since they are stated separately;
///   * index 0 of every coarse group returns the base colour byte for byte, which is what keeps the
///     user guide's static legend and the existing colour language true;
///   * shades within a group are distinct, which is the only thing that makes the derivation worth
///     doing at all;
///   * the filter predicate keys off the ACTIVE vocabulary, which is why the filter is cleared when
///     the vocabulary flips;
///   * a restyle preserves the alpha the builder chose, which is the only thing keeping the
///     co-planar door/window fills from z-fighting again;
///   * the tap's node walk accepts nothing but a category name, so a tap on the mesh or on a
///     container is never reported as a detection.
final class SemanticLabelDetailTests: XCTestCase {

    /// Exactly the strings `RoomPlanExporter.categoryString` writes for surfaces — transcribed by
    /// hand, because that function is `private` and cannot be called from here. So the assertions
    /// below pin the ENUM against this transcription, not the exporter against the enum: a change to
    /// `RoomPlanExporter` still has to be mirrored here deliberately.
    private let surfaceStrings = ["wall", "floor", "door", "window", "opening"]
    /// Exactly the strings `RoomPlanExporter.objectCategoryString` writes for objects (same
    /// hand-transcription caveat as above).
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
                XCTFail("\(raw) does not parse as a RoomPlanCategory")
                continue
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

    /// The ramp is a function of ALL THREE of its arguments, and of the side its index falls on.
    ///
    /// Deliberately NOT `XCTAssertEqual(x, x)`: a pure function of constants satisfies that
    /// trivially, so it pins nothing at all. Each inequality below is one a "discards its argument"
    /// mutation breaks — dropping `index`, dropping `groupCount` from the hue window, dropping
    /// `base`, or making `side` a constant instead of alternating.
    func testDerivedShadeDependsOnEveryArgument() {
        let purple = SIMD4<Float>(0.7, 0.3, 0.9, 1)
        let red = SIMD4<Float>(1.0, 0.2, 0.2, 1)
        // A mirrored PAIR shares its step and reach, so only `side` separates 1 from 2 and 3 from 4.
        // A constant `side` collapses each pair onto one colour and fails here.
        XCTAssertNotEqual(RoomPlanCategory.derivedShade(base: purple, index: 1, groupCount: 12),
                          RoomPlanCategory.derivedShade(base: purple, index: 2, groupCount: 12))
        XCTAssertNotEqual(RoomPlanCategory.derivedShade(base: purple, index: 3, groupCount: 12),
                          RoomPlanCategory.derivedShade(base: purple, index: 4, groupCount: 12))
        // A different step is a different shade, so the index is read rather than ignored.
        XCTAssertNotEqual(RoomPlanCategory.derivedShade(base: purple, index: 1, groupCount: 12),
                          RoomPlanCategory.derivedShade(base: purple, index: 3, groupCount: 12))
        // 4 and 5 members share `maxStep` (2), hence the same reach and side at every index below —
        // so the ONLY thing that can separate them is the hue window widening with group size.
        for index in 1...3 {
            XCTAssertNotEqual(RoomPlanCategory.derivedShade(base: purple, index: index, groupCount: 4),
                              RoomPlanCategory.derivedShade(base: purple, index: index, groupCount: 5),
                              "the window did not widen from 4 to 5 members at index \(index)")
        }
        // The anchor is carried through, not discarded for a fixed ramp.
        XCTAssertNotEqual(RoomPlanCategory.derivedShade(base: purple, index: 1, groupCount: 12),
                          RoomPlanCategory.derivedShade(base: red, index: 1, groupCount: 12))
    }

    /// `fullDetailColor` routes through `derivedShade` at the category's OWN index within its coarse
    /// group. That index is what makes a stove a different purple from a sink, and an off-by-one in
    /// it would reshuffle a whole group without failing anything else in this file.
    func testFullDetailColorUsesTheCategoryIndexWithinItsGroup() {
        let fixtureGroup = RoomPlanCategory.categories(in: .fixture)
        XCTAssertEqual(fixtureGroup.first, RoomPlanCategory.storage,
                       "fixture group order changed — the index pins below are stale")
        XCTAssertEqual(fixtureGroup.last, RoomPlanCategory.stairs)
        let fixture = SemanticClass.fixture.color
        XCTAssertEqual(RoomPlanCategory.storage.fullDetailColor,
                       RoomPlanCategory.derivedShade(base: fixture, index: 0, groupCount: 12))
        XCTAssertEqual(RoomPlanCategory.refrigerator.fullDetailColor,
                       RoomPlanCategory.derivedShade(base: fixture, index: 1, groupCount: 12))
        XCTAssertEqual(RoomPlanCategory.stove.fullDetailColor,
                       RoomPlanCategory.derivedShade(base: fixture, index: 2, groupCount: 12))
        XCTAssertEqual(RoomPlanCategory.stairs.fullDetailColor,
                       RoomPlanCategory.derivedShade(base: fixture, index: 11, groupCount: 12))
        // Seat is the small-group case: chair anchors, sofa and bed are the mirrored pair.
        let seat = SemanticClass.seat.color
        XCTAssertEqual(RoomPlanCategory.chair.fullDetailColor, seat)
        XCTAssertEqual(RoomPlanCategory.sofa.fullDetailColor,
                       RoomPlanCategory.derivedShade(base: seat, index: 1, groupCount: 3))
        XCTAssertEqual(RoomPlanCategory.bed.fullDetailColor,
                       RoomPlanCategory.derivedShade(base: seat, index: 2, groupCount: 3))
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

    /// The hue window stops widening at `fullDetailMaxHueSpan`, which is what keeps `.fixture`'s 12
    /// members inside purple instead of walking them into the blue that means "wall".
    ///
    /// Asserted THROUGH `derivedShade`, not by recomputing the window from the three constants: a
    /// test that restates the formula passes whatever the implementation does with it, so deleting
    /// the `min(fullDetailMaxHueSpan, …)` outright would go unnoticed. 24 and 25 members share
    /// `maxStep` (12), hence the same reach and side at every index below, so the only thing that
    /// can make their shades AGREE is the cap — uncapped their windows would be 0.50 and 0.52.
    func testHueWindowStaysCapped() {
        XCTAssertLessThan(RoomPlanCategory.fullDetailBaseHueSpan,
                          RoomPlanCategory.fullDetailMaxHueSpan)
        XCTAssertGreaterThan(RoomPlanCategory.fullDetailHueSpanGrowth, 0)
        let base = SIMD4<Float>(0.7, 0.3, 0.9, 1)
        for index in 1...6 {
            XCTAssertEqual(RoomPlanCategory.derivedShade(base: base, index: index, groupCount: 24),
                           RoomPlanCategory.derivedShade(base: base, index: index, groupCount: 25),
                           "the hue window is not capped at index \(index)")
        }
        // …and the cap has to BIND for the group the palette was designed around, or it is
        // decoration: 12 members ask for a window wider than the cap allows.
        XCTAssertGreaterThan(RoomPlanCategory.fullDetailBaseHueSpan
                                + RoomPlanCategory.fullDetailHueSpanGrowth * 10,
                             RoomPlanCategory.fullDetailMaxHueSpan)
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
            XCTAssertFalse(detail.accessibilityValue.isEmpty)
        }
        XCTAssertFalse(SemanticLabelDetail.accessibilityLabel.isEmpty)
    }

    /// The persisted default has to parse back, or every preview would silently fall back to coarse
    /// and the persistence would look broken rather than absent. It also pins the compatibility
    /// claim the whole change rests on: the default is COARSE, so an existing preview is unchanged
    /// until someone asks for the rich set.
    func testPersistedDefaultParses() {
        XCTAssertEqual(SemanticLabelDetail(rawValue: AppConstants.semanticLabelDetail), .coarse)
    }

    // MARK: - The node walk and the styling write
    //
    // SceneKit, but no renderer and no device: `semanticLabelOwner` only reads `name` and `parent`,
    // and `styleSemanticNode` only writes `isHidden` and one material's `diffuse.contents`.

    /// A hit-test result names the node owning the hit GEOMETRY, which is not necessarily the node
    /// carrying the label, so the resolver walks up — bounded, and accepting only names that parse
    /// as a category.
    @MainActor
    func testSemanticLabelOwnerWalksUpToTheNamedNode() {
        let box = SCNNode()
        box.name = "sofa"
        guard let (directOwner, directCategory) = MeshPreviewView.semanticLabelOwner(of: box) else {
            return XCTFail("a node named \"sofa\" resolved to no label at all")
        }
        XCTAssertEqual(directCategory, RoomPlanCategory.sofa)
        XCTAssertTrue(directOwner === box)

        // A child of the box does not carry the label, so the walk has to find the parent — and
        // must report the PARENT as the owner, because that is the node the confidence table is
        // keyed by.
        let child = SCNNode()
        box.addChildNode(child)
        guard let (owner, category) = MeshPreviewView.semanticLabelOwner(of: child) else {
            return XCTFail("the walk did not reach the labelled parent")
        }
        XCTAssertEqual(category, RoomPlanCategory.sofa)
        XCTAssertTrue(owner === box, "the walk reported the child rather than the labelled parent")

        // Every container name the boxes actually live under, and every mesh node in the scene: a
        // tap landing on one of these must resolve to nothing rather than to a detection.
        for name in ["semantics", "semanticFills", "timelineSlot", "mesh", "proxyMesh",
                     "dynamicMesh"] {
            XCTAssertNil(RoomPlanCategory(rawValue: name), "\(name) now parses as a category")
            let node = SCNNode()
            node.name = name
            XCTAssertNil(MeshPreviewView.semanticLabelOwner(of: node), name)
        }

        // The walk is bounded, so a deep hierarchy cannot turn a tap into a climb to the root that
        // finds an unrelated ancestor's label.
        var deep = SCNNode()
        box.addChildNode(deep)
        for _ in 0..<5 {
            let next = SCNNode()
            deep.addChildNode(next)
            deep = next
        }
        XCTAssertNil(MeshPreviewView.semanticLabelOwner(of: deep))
    }

    /// The restyle preserves the alpha the builder chose rather than recomputing it. That is the
    /// only thing keeping a door/window fill at 0.3 — lose it and the co-planar boxes z-fight again,
    /// which is a rendering fault no other test here would see.
    @MainActor
    func testStyleSemanticNodePreservesAlphaAcrossADetailChange() {
        // An OPENING fill, exactly as the loader builds it: the door class's colour at 0.3. Opening
        // rather than door on purpose — door is index 0 of its group, so its full-detail colour is
        // the base and a "detail is ignored" mutation would not show.
        let doorBase = SemanticClass.door.color
        let fill = makeStyledNode(name: "opening", color: doorBase, alpha: 0.3)

        MeshPreviewView.styleSemanticNode(fill, detail: .coarse, hiddenLabels: [])
        XCTAssertEqual(diffuseAlpha(of: fill), 0.3, accuracy: 1e-5,
                       "an opening fill lost its anti-z-fighting alpha")
        // Coarse detail must leave the colour exactly where the builder put it.
        XCTAssertEqual(diffuseColor(of: fill), uiColor(doorBase, alpha: diffuseAlpha(of: fill)),
                       "coarse detail changed an opening's colour")
        let coarseColor = diffuseColor(of: fill)

        MeshPreviewView.styleSemanticNode(fill, detail: .full, hiddenLabels: [])
        XCTAssertEqual(diffuseAlpha(of: fill), 0.3, accuracy: 1e-5,
                       "the detail flip dropped the fill's alpha")
        XCTAssertEqual(diffuseColor(of: fill),
                       uiColor(RoomPlanCategory.opening.fullDetailColor,
                               alpha: diffuseAlpha(of: fill)))
        XCTAssertNotEqual(diffuseColor(of: fill), coarseColor,
                          "the detail flip recoloured nothing")

        // An opaque box — the alpha the loader gives the WIREFRAME half — keeps 1.0, and restyling
        // is idempotent rather than compounding. (The fixture's geometry is a solid box either way;
        // only the material's alpha is under test here.)
        let wire = makeStyledNode(name: "sofa", color: SemanticClass.seat.color, alpha: 1)
        MeshPreviewView.styleSemanticNode(wire, detail: .full, hiddenLabels: [])
        let once = diffuseColor(of: wire)
        MeshPreviewView.styleSemanticNode(wire, detail: .full, hiddenLabels: [])
        XCTAssertEqual(diffuseAlpha(of: wire), 1, accuracy: 1e-5)
        XCTAssertEqual(diffuseColor(of: wire), once, "restyling compounded instead of repeating")
    }

    /// The filter writes `isHidden` on the box and keys off the ACTIVE vocabulary; a name this build
    /// cannot parse is left entirely alone, colour and visibility both.
    @MainActor
    func testStyleSemanticNodeAppliesTheFilterAndSkipsUnknownNames() {
        let sofa = makeStyledNode(name: "sofa", color: SemanticClass.seat.color, alpha: 0.75)

        MeshPreviewView.styleSemanticNode(sofa, detail: .full, hiddenLabels: ["sofa"])
        XCTAssertTrue(sofa.isHidden)
        MeshPreviewView.styleSemanticNode(sofa, detail: .full, hiddenLabels: [])
        XCTAssertFalse(sofa.isHidden, "clearing the filter did not bring the box back")
        // At coarse detail the row that hides a sofa is "seat" — "sofa" is not a row at all.
        MeshPreviewView.styleSemanticNode(sofa, detail: .coarse, hiddenLabels: ["sofa"])
        XCTAssertFalse(sofa.isHidden)
        MeshPreviewView.styleSemanticNode(sofa, detail: .coarse, hiddenLabels: ["seat"])
        XCTAssertTrue(sofa.isHidden)

        // Unparseable name: untouched. It has no legend row, so a filter naming it must not hide it
        // — there would be no way to bring it back.
        let unknown = makeStyledNode(name: "unknown", color: SemanticClass.fixture.color, alpha: 0.75)
        let before = diffuseColor(of: unknown)
        MeshPreviewView.styleSemanticNode(unknown, detail: .full, hiddenLabels: ["unknown"])
        XCTAssertEqual(diffuseColor(of: unknown), before, "an unnameable box was recoloured")
        XCTAssertFalse(unknown.isHidden, "an unnameable box was hidden by a filter that cannot name it")
    }

    // MARK: Fixtures for the two node tests

    /// One semantic box as the loader leaves it: a single material whose diffuse colour carries the
    /// class colour and the builder's opacity.
    @MainActor
    private func makeStyledNode(name: String, color: SIMD4<Float>, alpha: CGFloat) -> SCNNode {
        let material = SCNMaterial()
        material.diffuse.contents = uiColor(color, alpha: alpha)
        let geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        geometry.materials = [material]
        let node = SCNNode()
        node.geometry = geometry
        node.name = name
        return node
    }

    private func uiColor(_ rgba: SIMD4<Float>, alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat(rgba.x), green: CGFloat(rgba.y), blue: CGFloat(rgba.z), alpha: alpha)
    }

    @MainActor
    private func diffuseColor(of node: SCNNode) -> UIColor? {
        node.geometry?.firstMaterial?.diffuse.contents as? UIColor
    }

    /// -1 when there is no colour to read, so a missing material fails an assertion rather than
    /// silently passing one.
    @MainActor
    private func diffuseAlpha(of node: SCNNode) -> CGFloat {
        diffuseColor(of: node)?.cgColor.alpha ?? -1
    }
}

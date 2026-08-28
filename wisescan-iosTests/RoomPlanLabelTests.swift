import XCTest
import simd
import SceneKit
import UIKit
import SwiftUI
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
///   * the filter predicate keys off the category, so one row hides one label;
///   * a restyle preserves the alpha the builder chose, which is the only thing keeping the
///     co-planar door/window fills from z-fighting again;
///   * the tap's node walk accepts nothing but a category name, so a tap on the mesh or on a
///     container is never reported as a detection.
final class RoomPlanLabelTests: XCTestCase {

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
        XCTAssertEqual(RoomPlanCategory.color(forCategory: "unknown"), SemanticClass.none.color)
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

    /// The raw-string entry point the renderer uses (the node only ever holds the string) returns
    /// the derived shade — there is no second, coarser palette to route to any more.
    func testRawStringColourRoutesToTheDerivedShade() {
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(RoomPlanCategory.color(forCategory: category.rawValue),
                           category.fullDetailColor, category.rawValue)
        }
        // A category this build cannot parse is not drawn, and says so in the only way the renderer
        // understands.
        XCTAssertEqual(RoomPlanCategory.color(forCategory: "unknown"), SemanticClass.none.color)
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

    /// The legend key IS the row identity, and there is one row per CATEGORY: a sofa is its own
    /// row, not part of a "seat" row.
    func testLegendKeyIsTheCategoryItself() {
        XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: "sofa"), "sofa")
        XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: "opening"), "opening")
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(RoomPlanCategory.legendKey(forCategory: category.rawValue),
                           category.rawValue)
        }
    }

    /// Nothing is filtered by an empty selection — the default state must draw everything.
    func testEmptySelectionHidesNothing() {
        for category in RoomPlanCategory.allCases {
            XCTAssertTrue(RoomPlanCategory.isVisible(category: category.rawValue, hiddenLabels: []),
                          category.rawValue)
        }
    }

    /// A row filters exactly one category — the sofa goes, the chair and the bed stay.
    ///
    /// The flip side, and the deliberate cost of dropping the coarse vocabulary: hiding a whole
    /// group is one tap per member. This test is where that shows up, so a future "hide the group"
    /// affordance has somewhere obvious to be pinned.
    func testARowFiltersExactlyOneCategory() {
        let hidden: Set<String> = ["sofa"]
        for category in RoomPlanCategory.allCases {
            XCTAssertEqual(RoomPlanCategory.isVisible(category: category.rawValue,
                                                      hiddenLabels: hidden),
                           category != .sofa, category.rawValue)
        }
        // A coarse class name is not a row identity any more, so it filters nothing — including the
        // five names the two vocabularies used to spell identically, whose collision is what made
        // the old toggle clear the filter on every flip.
        XCTAssertTrue(RoomPlanCategory.isVisible(category: "sofa", hiddenLabels: ["seat"]))
        XCTAssertTrue(RoomPlanCategory.isVisible(category: "chair", hiddenLabels: ["seat"]))
        XCTAssertTrue(RoomPlanCategory.isVisible(category: "stove", hiddenLabels: ["fixture"]))
    }

    /// A label the filter cannot name is never hidden by it: an unparseable category (and an unnamed
    /// node) has no legend row, so the filter has nothing to say about it. Without this, an unknown
    /// category could be hidden with no row to bring it back.
    func testUnnameableLabelsAreNeverFiltered() {
        XCTAssertNil(RoomPlanCategory.legendKey(forCategory: "unknown"))
        XCTAssertNil(RoomPlanCategory.legendKey(forCategory: nil))
        XCTAssertTrue(RoomPlanCategory.isVisible(category: "unknown",
                                                 hiddenLabels: ["unknown", "wall", "sofa"]))
        XCTAssertTrue(RoomPlanCategory.isVisible(category: nil,
                                                 hiddenLabels: ["unknown", "wall", "sofa"]))
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
    ///
    /// Feeds it the COARSE colour the loader used to build with, which is not what any live box
    /// carries any more (`buildRoomPlanOutlines` now builds in the final shade). That is the point:
    /// it proves the restyle reaches the right colour from a wrong starting one, so the two paths
    /// cannot silently drift apart.
    @MainActor
    func testStyleSemanticNodePreservesAlphaWhileRecolouring() {
        // An OPENING fill: the door class's colour at 0.3. Opening rather than door on purpose —
        // door is index 0 of its group, so its shade IS the base and a "never recolours" mutation
        // would not show.
        let doorBase = SemanticClass.door.color
        let fill = makeStyledNode(name: "opening", color: doorBase, alpha: 0.3)

        MeshPreviewView.styleSemanticNode(fill, hiddenLabels: [])
        XCTAssertEqual(diffuseAlpha(of: fill), 0.3, accuracy: 1e-5,
                       "an opening fill lost its anti-z-fighting alpha")
        XCTAssertEqual(diffuseColor(of: fill),
                       uiColor(RoomPlanCategory.opening.fullDetailColor,
                               alpha: diffuseAlpha(of: fill)))
        XCTAssertNotEqual(diffuseColor(of: fill), uiColor(doorBase, alpha: 0.3),
                          "the restyle recoloured nothing")

        // An opaque box — the alpha the loader gives the WIREFRAME half — keeps 1.0, and restyling
        // is idempotent rather than compounding.
        let wire = makeStyledNode(name: "sofa", color: SemanticClass.seat.color, alpha: 1)
        MeshPreviewView.styleSemanticNode(wire, hiddenLabels: [])
        let once = diffuseColor(of: wire)
        MeshPreviewView.styleSemanticNode(wire, hiddenLabels: [])
        XCTAssertEqual(diffuseAlpha(of: wire), 1, accuracy: 1e-5)
        XCTAssertEqual(diffuseColor(of: wire), once, "restyling compounded instead of repeating")
    }

    /// The filter writes `isHidden` on the box, keyed by category; a name this build cannot parse is
    /// left entirely alone, colour and visibility both.
    @MainActor
    func testStyleSemanticNodeAppliesTheFilterAndSkipsUnknownNames() {
        let sofa = makeStyledNode(name: "sofa", color: SemanticClass.seat.color, alpha: 0.75)

        MeshPreviewView.styleSemanticNode(sofa, hiddenLabels: ["sofa"])
        XCTAssertTrue(sofa.isHidden)
        MeshPreviewView.styleSemanticNode(sofa, hiddenLabels: [])
        XCTAssertFalse(sofa.isHidden, "clearing the filter did not bring the box back")
        // The sofa's coarse group is not a row, so naming it filters nothing.
        MeshPreviewView.styleSemanticNode(sofa, hiddenLabels: ["seat"])
        XCTAssertFalse(sofa.isHidden)

        // Unparseable name: untouched. It has no legend row, so a filter naming it must not hide it
        // — there would be no way to bring it back.
        let unknown = makeStyledNode(name: "unknown", color: SemanticClass.fixture.color, alpha: 0.75)
        let before = diffuseColor(of: unknown)
        MeshPreviewView.styleSemanticNode(unknown, hiddenLabels: ["unknown"])
        XCTAssertEqual(diffuseColor(of: unknown), before, "an unnameable box was recoloured")
        XCTAssertFalse(unknown.isHidden, "an unnameable box was hidden by a filter that cannot name it")
    }

    // MARK: Fixtures for the two node tests

    // MARK: - Bulk show-all / hide-all

    /// "Hide all" means every row the legend is OFFERING, not every category the vocabulary has.
    /// The distinction is the whole safety property: hiding a key with no row would leave geometry
    /// switched off with no control able to bring it back.
    func testHideAllCoversExactlyTheOfferedRows() {
        let offered = [RoomPlanCategory.wall, .floor, .stairs]
        let hidden = Set(offered.map(\.rawValue))

        for category in offered {
            XCTAssertFalse(RoomPlanCategory.isVisible(category: category.rawValue,
                                                      hiddenLabels: hidden), category.rawValue)
        }
        // A category the legend never listed is untouched — it is not on screen to hide.
        XCTAssertTrue(RoomPlanCategory.isVisible(category: "sofa", hiddenLabels: hidden))
        // And clearing the set is the exact inverse: nothing hidden, whatever was offered.
        for category in RoomPlanCategory.allCases {
            XCTAssertTrue(RoomPlanCategory.isVisible(category: category.rawValue, hiddenLabels: []),
                          category.rawValue)
        }
    }

    /// Hiding everything must still leave every row on screen — dimmed and struck through — or
    /// there is no way back. Pins the two states the row renders, since the "way back" is the row
    /// itself rather than a separate control.
    @MainActor
    func testHiddenRowsStillRenderAsTheWayBack() {
        let hidden = SemanticLegendRow(color: .purple, label: "Stove", isFiltered: true, toggle: {})
        let shown = SemanticLegendRow(color: .purple, label: "Stove", isFiltered: false, toggle: {})
        XCTAssertTrue(hidden.isFiltered)
        XCTAssertFalse(shown.isFiltered)
        // A row with no toggle is the unfilterable fallback (a category this build cannot parse);
        // one with a toggle is a control. Nothing else distinguishes them.
        XCTAssertNil(SemanticLegendRow(color: Color.gray, label: "Fixture").toggle)
        XCTAssertNotNil(shown.toggle)
    }

    // MARK: - Legend sizing

    /// The legend rows are tap targets, so a regular-width screen (any iPad, a large phone in
    /// landscape) gets a materially bigger row than a phone — not a token bump. Pins the direction
    /// and the rough magnitude, which is what a later "tidy the numbers" edit could undo silently.
    func testRegularWidthRowsAreSubstantiallyLarger() {
        let compact = SemanticLegendMetrics.compact
        let regular = SemanticLegendMetrics.regular

        // Total row height is the swatch plus its padding above and below.
        let compactRow = compact.swatch + compact.rowPadding * 2
        let regularRow = regular.swatch + regular.rowPadding * 2
        XCTAssertGreaterThan(regularRow, compactRow * 1.25,
                             "the regular-width row is not meaningfully easier to hit")
        XCTAssertLessThan(regularRow, compactRow * 2,
                          "the regular-width row grew enough to crowd a 21-row legend off screen")

        XCTAssertGreaterThan(regular.swatch, compact.swatch)
        XCTAssertGreaterThan(regular.cardPadding, compact.cardPadding)
        XCTAssertGreaterThan(regular.rowSpacing, compact.rowSpacing)
    }

    /// The size class picks between them, and anything unknown falls back to the phone numbers —
    /// the layout that fits everywhere.
    func testSizeClassSelectsTheMetrics() {
        XCTAssertEqual(SemanticLegendMetrics.forSizeClass(.regular).swatch,
                       SemanticLegendMetrics.regular.swatch)
        XCTAssertEqual(SemanticLegendMetrics.forSizeClass(.compact).swatch,
                       SemanticLegendMetrics.compact.swatch)
        XCTAssertEqual(SemanticLegendMetrics.forSizeClass(nil).swatch,
                       SemanticLegendMetrics.compact.swatch)
    }

    // MARK: - Timeline legend union
    //
    // The legend a timeline prints is the union over every LOADED generation, not the visible one's
    // list, because its rows are also the filter's controls. What these check is that the union is
    // a set operation with a canonical order and that the order does not depend on load order —
    // which it would if the fold appended, since the pump loads generations nearest-scrub-first.

    /// Two generations that detected different things produce one legend naming both.
    func testUnionCoversEveryGenerationsLabels() {
        let first: [SemanticClass] = [.wall, .floor]
        let second: [SemanticClass] = [.floor, .seat]
        let merged = ScanTimelineState.mergedVocabulary(first, second)
        XCTAssertEqual(Set(merged), Set([.wall, .floor, .seat] as [SemanticClass]))
        XCTAssertEqual(merged.count, 3, "floor, detected by both generations, was listed twice")
    }

    /// The union is ordered by `allCases`, NOT by the order generations happened to load — the pump
    /// loads nearest-to-the-scrub-position first, so an appending fold would print one location's
    /// legend differently depending on which scan card the viewer was opened by.
    func testUnionOrderIsIndependentOfLoadOrder() {
        let canonical = SemanticClass.allCases.filter { [.wall, .floor, .seat].contains($0) }
        let forwards = ScanTimelineState.mergedVocabulary([.wall] as [SemanticClass],
                                                          [.seat, .floor])
        let backwards = ScanTimelineState.mergedVocabulary([.seat] as [SemanticClass],
                                                           [.floor, .wall])
        XCTAssertEqual(forwards, canonical)
        XCTAssertEqual(backwards, canonical)
        XCTAssertEqual(forwards, backwards)

        // Same rule over the rich vocabulary, where the group order is also the palette's index
        // order — a legend sorted by load order would pair rows with shades that fan out in a
        // different sequence.
        let rich = ScanTimelineState.mergedVocabulary([RoomPlanCategory.stairs],
                                                      [.wall, .refrigerator])
        XCTAssertEqual(rich, RoomPlanCategory.allCases.filter {
            [.stairs, .wall, .refrigerator].contains($0)
        })
    }

    /// A generation with no RoomPlan geometry at all must not empty the legend built from its
    /// siblings — scrubbing onto a mesh-only rescan would otherwise drop every filter control (and
    /// with it the way back to any label the user had switched off).
    func testGenerationWithNoLabelsLeavesTheUnionAlone() {
        let existing: [SemanticClass] = [.wall, .table]
        XCTAssertEqual(ScanTimelineState.mergedVocabulary(existing, []), existing)
        XCTAssertTrue(ScanTimelineState.mergedVocabulary([] as [SemanticClass], []).isEmpty)
    }

    /// The fold as the slot attach actually calls it, and the property the whole design rests on: a
    /// label only ONE generation detected still gets a row, and the filter keyed to that row hides
    /// nothing in the generations that lack it (rather than being unavailable there).
    @MainActor
    func testFoldingSlotsBuildsTheLegendAndAnAbsentLabelFiltersHarmlessly() {
        let state = ScanTimelineState()
        state.addSemanticVocabulary(classes: [.wall, .floor],
                                    categories: [.wall, .floor])
        state.addSemanticVocabulary(classes: [.wall, .fixture],
                                    categories: [.wall, .stairs])
        XCTAssertEqual(state.unionClasses, SemanticClass.allCases.filter {
            [.wall, .floor, .fixture].contains($0)
        })
        XCTAssertEqual(state.unionCategories, RoomPlanCategory.allCases.filter {
            [.wall, .floor, .stairs].contains($0)
        })

        // Switch off the row only the second generation can draw. The first generation's boxes are
        // untouched by it, which is what "the row is there but hides nothing here" means.
        let hidden: Set<String> = ["stairs"]
        XCTAssertFalse(RoomPlanCategory.isVisible(category: "stairs", hiddenLabels: hidden))
        for present in ["wall", "floor"] {
            XCTAssertTrue(RoomPlanCategory.isVisible(category: present, hiddenLabels: hidden),
                          present)
        }
    }

    // MARK: - Tap confinement

    /// The hit test cannot ignore hidden nodes (the fill boxes it aims at are hidden in
    /// `.meshWithOutlines`), so while a timeline is active EVERY generation's boxes are hit-testable
    /// — including the containers that are switched off. `isDescendant` is the whole of what keeps a
    /// tap from naming a box in a generation that is not on screen.
    @MainActor
    func testTapConfinementAcceptsOnlyTheVisibleGenerationsSubtree() {
        let root = SCNNode()
        let visible = SCNNode()
        visible.name = "timelineSlot"
        let hiddenSlot = SCNNode()
        hiddenSlot.name = "timelineSlot"
        hiddenSlot.isHidden = true
        root.addChildNode(visible)
        root.addChildNode(hiddenSlot)

        // A box two levels down in each slot, which is where the loader actually puts them
        // (slot container → semantics/semanticFills → box).
        func box(named name: String, in slot: SCNNode) -> SCNNode {
            let group = SCNNode()
            group.name = "semanticFills"
            slot.addChildNode(group)
            let node = SCNNode()
            node.name = name
            group.addChildNode(node)
            return node
        }
        let onScreen = box(named: "sofa", in: visible)
        let offScreen = box(named: "stove", in: hiddenSlot)

        XCTAssertTrue(MeshPreviewView.isDescendant(onScreen, of: visible))
        XCTAssertFalse(MeshPreviewView.isDescendant(offScreen, of: visible),
                       "a box in a switched-off generation passed the visible-subtree check")
        // Being hidden is not what excludes it — the containment is. Both slots are equally
        // hit-testable, and the off-screen box belongs to the OTHER root.
        XCTAssertTrue(MeshPreviewView.isDescendant(offScreen, of: hiddenSlot))
        XCTAssertTrue(MeshPreviewView.isDescendant(visible, of: visible),
                      "a root must contain itself, or a hit on the container node is dropped")
        XCTAssertTrue(MeshPreviewView.isDescendant(onScreen, of: root))
    }

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

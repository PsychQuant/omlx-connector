import XCTest

@testable import OmlxConnectorCore

/// The launcher works around two upstream oMLX bugs. The user's decision was that
/// it keeps existing after they are fixed — it also carries distribution, UX and a
/// wider settings override — but that it should say so rather than rely on someone
/// remembering to re-check.
///
/// The obvious design, a "fixed in version X" constant, cannot work: that number
/// does not exist yet, and filling it in later is the same act of remembering we
/// are trying to remove. So the check runs the other way round — it records the
/// version this workaround was last verified against and speaks up when the ground
/// moves underneath it.
final class UpstreamWorkaroundStalenessTests: XCTestCase {

    func testSameVersionAsVerifiedBaselineIsSilent() {
        XCTAssertNil(
            UpstreamWorkaround.stalenessNotice(
                installedOmlxVersion: UpstreamWorkaround.lastVerifiedOmlxVersion))
    }

    func testOlderInstallIsSilent() {
        // Nagging someone running an older oMLX is pure noise: the workaround was
        // verified against something newer than what they have, so nothing changed
        // under it.
        XCTAssertNil(UpstreamWorkaround.stalenessNotice(installedOmlxVersion: "0.5.9"))
    }

    func testNewerInstallNamesBothUpstreamIssues() throws {
        let notice = try XCTUnwrap(
            UpstreamWorkaround.stalenessNotice(installedOmlxVersion: "0.7.2"))
        // The notice has to be actionable on its own — someone reading it in a
        // terminal should not have to go find out which bugs are meant.
        XCTAssertTrue(notice.contains("2715"), "notice should name jundot/omlx#2715")
        XCTAssertTrue(notice.contains("2716"), "notice should name jundot/omlx#2716")
        XCTAssertTrue(notice.contains("0.7.2"), "notice should name the installed version")
    }

    func testReleaseCandidateOfTheBaselineIsSilent() {
        // Baseline is 0.6.4. The release candidates that led up to it are *older*,
        // so they must stay silent. This is the direction that breaks if the
        // comparator ever reads a pre-release tag as an increment.
        XCTAssertNil(UpstreamWorkaround.stalenessNotice(installedOmlxVersion: "0.6.4rc1"))
    }

    func testReleaseCandidateOfALaterVersionTriggers() {
        // The other direction, so neither test can pass by refusing everything:
        // 0.6.5rc1 is past the baseline even though it is not a final release.
        XCTAssertNotNil(UpstreamWorkaround.stalenessNotice(installedOmlxVersion: "0.6.5rc1"))
    }

    // `staleness` has three outcomes; `stalenessNotice` reports only one of them. The
    // test below (`testUnparseableVersionIsSilent`) is correct about the helper and was
    // the reason this gap stayed invisible: reading it, "unparseable" looks handled. It is
    // handled for `stalenessNotice` and, until these cases, untested for `staleness`.
    // Keep both — they assert different functions, and collapsing either loses coverage.

    func testUnreadableWhenVersionIsNil() {
        // `omlx --version` failing is not the same as "nothing to say". The launcher's
        // recorded promise is that it never goes quiet about an unchecked baseline.
        guard case .unreadable(let notice) = UpstreamWorkaround.staleness(installedOmlxVersion: nil)
        else { return XCTFail("nil version must be .unreadable, not silence") }
        XCTAssertTrue(notice.contains(UpstreamWorkaround.lastVerifiedOmlxVersion),
                      "the notice must name the baseline, or it is not actionable")
    }

    func testUnreadableWhenVersionIsEmpty() {
        // A separate guard clause from the nil case. Tested separately so deleting the
        // `!raw.isEmpty` half cannot stay green.
        guard case .unreadable = UpstreamWorkaround.staleness(installedOmlxVersion: "")
        else { return XCTFail("empty version must be .unreadable") }
    }

    func testUnreadableQuotesTheUnparseableStringBack() {
        // The scenario the doc comment names: `omlx --version` printing `omlx 0.7.0`
        // instead of `0.7.0`. Quoting the raw string is what makes the notice actionable —
        // without it the reader cannot tell what the parser choked on.
        guard case .unreadable(let notice) =
                UpstreamWorkaround.staleness(installedOmlxVersion: "omlx 0.7.0")
        else { return XCTFail("unparseable version must be .unreadable, not .quiet") }
        XCTAssertTrue(notice.contains("omlx 0.7.0"), "notice should quote the raw version back")
    }

    func testTheTwoUnreadableSitesSayDifferentThings() {
        // Case-only assertions would be satisfied by either site, so one guard could be
        // deleted unnoticed. The messages differ; require that.
        guard case .unreadable(let missing) = UpstreamWorkaround.staleness(installedOmlxVersion: nil),
              case .unreadable(let unparseable) =
                UpstreamWorkaround.staleness(installedOmlxVersion: "omlx 0.7.0")
        else { return XCTFail("both inputs must be .unreadable") }
        XCTAssertNotEqual(missing, unparseable,
                          "'could not read' and 'cannot parse' are different situations")
    }

    func testUnparseableVersionIsSilent() {
        // Fail quiet. A version string we cannot read is never a reason to get in
        // the way of launching.
        XCTAssertNil(UpstreamWorkaround.stalenessNotice(installedOmlxVersion: "garbage"))
        XCTAssertNil(UpstreamWorkaround.stalenessNotice(installedOmlxVersion: ""))
    }
}

/// The comparator is where this can quietly go wrong, so it is tested directly
/// rather than only through the notice.
final class OmlxVersionOrderingTests: XCTestCase {

    func testComponentsCompareNumericallyNotLexicographically() {
        // The classic one: "0.10.0" sorts before "0.9.0" as text, and after it as
        // a version. Getting this backwards makes the notice go silent for exactly
        // the releases most likely to carry the upstream fix.
        XCTAssertEqual(OmlxVersion.compare("0.10.0", "0.9.0"), .orderedDescending)
        XCTAssertEqual(OmlxVersion.compare("0.9.0", "0.10.0"), .orderedAscending)
    }

    func testMissingTrailingComponentsCountAsZero() {
        XCTAssertEqual(OmlxVersion.compare("0.6", "0.6.0"), .orderedSame)
        XCTAssertEqual(OmlxVersion.compare("1", "1.0.0"), .orderedSame)
    }

    func testPreReleaseSortsBeforeItsRelease() {
        XCTAssertEqual(OmlxVersion.compare("0.6.0rc1", "0.6.0"), .orderedAscending)
        XCTAssertEqual(OmlxVersion.compare("0.6.0", "0.6.0rc1"), .orderedDescending)
    }

    func testPreReleasesOrderByTheirOwnNumber() {
        XCTAssertEqual(OmlxVersion.compare("0.6.0rc1", "0.6.0rc2"), .orderedAscending)
        XCTAssertEqual(OmlxVersion.compare("0.6.0rc10", "0.6.0rc2"), .orderedDescending)
    }

    func testUnparseableReturnsNil() {
        XCTAssertNil(OmlxVersion.parse("garbage"))
        XCTAssertNil(OmlxVersion.parse(""))
        XCTAssertNil(OmlxVersion.parse("v"))
    }

    func testLeadingVIsTolerated() {
        // `omlx --version` prints a bare number today, but a leading "v" is common
        // enough elsewhere that refusing it would be a silly way to go silent.
        XCTAssertEqual(OmlxVersion.compare("v0.7.0", "0.6.0"), .orderedDescending)
    }
}

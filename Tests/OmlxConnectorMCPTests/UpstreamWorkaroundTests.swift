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

    func testReleaseOutranksItsOwnReleaseCandidate() {
        // Baseline is 0.6.0rc1. Plain 0.6.0 is the release that rc1 led up to, so
        // it is newer and must trigger the notice.
        XCTAssertNotNil(UpstreamWorkaround.stalenessNotice(installedOmlxVersion: "0.6.0"))
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

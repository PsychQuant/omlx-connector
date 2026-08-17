import XCTest

@testable import OmlxClaude
@testable import OmlxConnectorCore
@testable import OmlxConnectorMCP

/// The constraint `CLAUDE.md` calls "the one invariant that cannot regress".
///
/// Round 2 of verify found four reviewers independently reporting that `omlx-claude`
/// sat entirely outside it: a `grep` for the policy over `Sources/OmlxClaude/` returned
/// a single comment. The launcher would resolve any `OMLX_URL` and write it into
/// `ANTHROPIC_BASE_URL` at the highest precedence available, sending a whole session —
/// and the bearer token — anywhere it pointed, unwarned.
///
/// The policy now lives in `OmlxConnectorCore` so both entry points share **one**
/// implementation. Two copies of an invariant is one copy plus a future divergence.
final class LoopbackPolicyTests: XCTestCase {

    func testAcceptsEveryLoopbackForm() {
        for host in ["127.0.0.1", "127.1.2.3", "localhost", "LOCALHOST", "::1", "[::1]"] {
            XCTAssertTrue(LoopbackPolicy.isLoopback(host), "\(host) is loopback")
        }
    }

    func testRejectsRemoteAndNearMisses() {
        for host in ["api.openai.com", "192.168.0.10", "10.0.0.1", "127x.example.com",
                     "1270.0.0.1", "external.example"] {
            XCTAssertFalse(LoopbackPolicy.isLoopback(host), "\(host) is not loopback")
        }
    }

    func testRemoteOptInAcceptsOnlyTheLiteralOne() {
        XCTAssertTrue(LoopbackPolicy.allowsRemote(environment: ["OMLX_ALLOW_REMOTE": "1"]))
        for value in ["", "0", "true", "yes", "TRUE", " 1"] {
            XCTAssertFalse(
                LoopbackPolicy.allowsRemote(environment: ["OMLX_ALLOW_REMOTE": value]),
                "\(value) must not open the door")
        }
        XCTAssertFalse(LoopbackPolicy.allowsRemote(environment: [:]))
    }

    func testMCPServerStillUsesTheSamePolicy() {
        // The MCP side keeps its existing surface; it now forwards to Core rather than
        // carrying a second implementation. OmlxConnectorTests covers its behavior
        // unchanged — if that suite still passes, the forwarder is faithful.
        XCTAssertEqual(OmlxConfig.isLoopback("::1"), LoopbackPolicy.isLoopback("::1"))
        XCTAssertEqual(
            OmlxConfig.isLoopback("api.example.com"),
            LoopbackPolicy.isLoopback("api.example.com"))
    }
}

/// `omlx-claude` must refuse a non-loopback target exactly as the MCP server does.
final class LauncherLoopbackGateTests: XCTestCase {

    private func resolve(_ args: [String], _ env: [String: String] = [:]) -> Result<
        URL, LaunchError
    > {
        ProbeTarget.resolveChecked(arguments: args, environment: env)
    }

    func testDefaultIsAllowed() throws {
        XCTAssertEqual(try resolve([]).get().absoluteString, "http://127.0.0.1:8000")
    }

    func testRemoteOmlxUrlIsRefused() {
        // Reproduced live in round 2 before this gate existed:
        //   OMLX_URL=https://external.example/api omlx-claude
        // resolved, and would have been asserted into ANTHROPIC_BASE_URL.
        guard case .failure(let error) = resolve([], ["OMLX_URL": "https://external.example/api"])
        else { return XCTFail("a remote OMLX_URL must be refused") }
        guard case .nonLoopbackRefused(let host, _) = error else {
            return XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(host, "external.example")
    }

    func testRemoteHostFlagIsRefused() {
        guard case .failure = resolve(["--host", "gateway.corp"]) else {
            return XCTFail("a remote --host must be refused")
        }
    }

    func testRemoteIsPermittedWithTheExplicitOptIn() throws {
        let url = try resolve(
            ["--host", "gateway.corp"], ["OMLX_ALLOW_REMOTE": "1"]
        ).get()
        XCTAssertEqual(url.absoluteString, "http://gateway.corp:8000")
    }

    func testOptInAcceptsOnlyTheLiteralOne() {
        guard case .failure = resolve(["--host", "gateway.corp"], ["OMLX_ALLOW_REMOTE": "true"])
        else { return XCTFail("only \"1\" may open the door") }
    }

    func testLoopbackOverHttpsIsStillAllowed() throws {
        // The gate is about where content goes, not about the scheme.
        XCTAssertEqual(
            try resolve([], ["OMLX_URL": "https://127.0.0.1:8443/api"]).get().absoluteString,
            "https://127.0.0.1:8443/api")
    }
}

/// Round 1 fixed a SIGTRAP on `--host ::1` by bracketing anything containing a colon.
/// Round 2's adversarial pass showed that admitted garbage instead: `--host evil.com:9999`
/// became `http://[evil.com:9999]:8000` and the "unusable address" error became
/// unreachable. Bracketing now requires an actual IPv6 literal.
final class IPv6BracketingTests: XCTestCase {

    private func resolve(_ args: [String]) -> URL? {
        ProbeTarget.resolve(arguments: args, environment: ["OMLX_ALLOW_REMOTE": "1"])
    }

    func testRealIPv6LiteralsAreBracketed() {
        XCTAssertEqual(resolve(["--host", "::1"])?.absoluteString, "http://[::1]:8000")
        XCTAssertEqual(resolve(["--host", "[::1]"])?.absoluteString, "http://[::1]:8000")
        XCTAssertEqual(
            resolve(["--host", "2001:db8::1"])?.absoluteString, "http://[2001:db8::1]:8000")
    }

    func testColonBearingNonAddressesAreRefused() {
        // Each of these resolved to a usable-looking URL before this fix.
        for host in ["evil.com:9999", "x:y", "127.0.0.1:1", "host:80:80"] {
            XCTAssertNil(resolve(["--host", host]), "\(host) is not an address")
        }
    }

    func testZoneIdentifierIsPreserved() {
        // Link-local addresses legitimately carry a zone.
        XCTAssertEqual(
            resolve(["--host", "fe80::1%en0"])?.absoluteString, "http://[fe80::1%25en0]:8000")
    }
}

/// oMLX parses its flags with argparse, which accepts any unambiguous prefix. Round 2
/// proved — by running oMLX's own parser — that `--ho 127.0.0.1` is honoured there while
/// being invisible here, so a user who explicitly typed localhost could have the session
/// routed to whatever `OMLX_URL` held.
final class ArgparseAbbreviationTests: XCTestCase {

    func testUnambiguousPrefixesResolveLikeArgparse() {
        XCTAssertEqual(ProbeTarget.value(of: "--host", in: ["--ho", "h"]), "h")
        XCTAssertEqual(ProbeTarget.value(of: "--port", in: ["--po", "8001"]), "8001")
        XCTAssertEqual(ProbeTarget.value(of: "--port", in: ["--p", "8001"]), "8001")
        XCTAssertEqual(ProbeTarget.value(of: "--api-key", in: ["--ap", "k1"]), "k1")
        XCTAssertEqual(ProbeTarget.value(of: "--api-key", in: ["--a=k2"]), "k2")
    }

    func testAmbiguousPrefixesAreNotClaimed() {
        // `--h` could be --host or --haiku; argparse errors rather than guessing, and
        // we must not silently pick one.
        XCTAssertNil(ProbeTarget.value(of: "--host", in: ["--h", "h"]))
    }

    func testAPrefixOfAnotherOptionIsNotOurs() {
        XCTAssertNil(ProbeTarget.value(of: "--host", in: ["--ha", "some-model"]))
        XCTAssertNil(ProbeTarget.value(of: "--port", in: ["--opus", "m"]))
    }

    func testAbbreviationsObeyTheSameLastWinsAndDelimiterRules() {
        XCTAssertEqual(
            ProbeTarget.value(of: "--host", in: ["--host", "first", "--ho", "last"]), "last")
        XCTAssertNil(ProbeTarget.value(of: "--host", in: ["--", "--ho", "h"]))
    }

    func testExactSpellingStillWins() {
        XCTAssertEqual(ProbeTarget.value(of: "--host", in: ["--host", "h"]), "h")
    }
}

/// Round 3 found the gate was a string test, not an address test, and that the
/// near-miss fixtures above could not have caught it: every one of them breaks on the
/// character immediately after `127` (`x`, `0`), so none exercises a legitimate dot.
///
/// These cases are written to fail against `hasPrefix("127.")`. If a future change
/// makes them pass without also passing `testRejectsRemoteAndNearMisses`, the gate has
/// regressed to text matching again.
final class LoopbackIsAddressNotTextTests: XCTestCase {

    func testRegistrableNamesBeginningWith127AreNotLoopback() {
        // RFC 1123 permits a DNS label to start with a digit, so every one of these is
        // an ordinary hostname an attacker can register and point anywhere.
        for host in ["127.evil.example", "127.0.0.1.attacker.example",
                     "127.attacker.tld", "127.0.0.1.evil.com"] {
            XCTAssertFalse(LoopbackPolicy.isLoopback(host), "\(host) is a DNS name, not 127/8")
        }
    }

    func testEveryLoopbackAddressInThe127Block() {
        for host in ["127.0.0.1", "127.1.2.3", "127.255.255.254", "127.0.0.53"] {
            XCTAssertTrue(LoopbackPolicy.isLoopback(host), "\(host) is in 127/8")
        }
    }

    func testIPv6LoopbackInEverySpelling() {
        // Matching `::1` by string equality refused every other spelling of the same
        // address, which sent users to OMLX_ALLOW_REMOTE for a loopback host.
        for host in ["::1", "[::1]", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001"] {
            XCTAssertTrue(LoopbackPolicy.isLoopback(host), "\(host) is ::1")
        }
    }

    func testIPv4MappedLoopbackIsLoopback() {
        // ::ffff:127.0.0.1 reaches 127.0.0.1. Treating it as remote would be merely
        // annoying; treating a mapped *remote* address as local would not be.
        XCTAssertTrue(LoopbackPolicy.isLoopback("::ffff:127.0.0.1"))
        XCTAssertFalse(LoopbackPolicy.isLoopback("::ffff:8.8.8.8"))
    }

    func testNonLoopbackAddressesAndNamesStayRefused() {
        for host in ["128.0.0.1", "126.255.255.255", "0.0.0.0", "::",
                     "10.0.0.1", "api.openai.com", "localhost.evil.example"] {
            XCTAssertFalse(LoopbackPolicy.isLoopback(host), "\(host) must not be loopback")
        }
    }
}

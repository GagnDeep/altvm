import XCTest
import Compression
@testable import AltVMCore

/// Every test runs against a throwaway ALTVM_HOME so the user's real library is never touched.
class IsolatedHomeTestCase: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("altvm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("ALTVM_HOME", home.path, 1)
        try Paths.ensure()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        unsetenv("ALTVM_HOME")
    }
}

final class SpecAndProfileTests: IsolatedHomeTestCase {
    func testSpecRoundTripWithMillisecondDates() throws {
        var spec = VMSpec.defaults(name: "t", os: .linux)
        spec.labels["k"] = "v"
        spec.fastBoot = true
        let data = try JSON.encoder.encode(spec)
        let back = try JSON.decoder.decode(VMSpec.self, from: data)
        XCTAssertEqual(back.name, "t")
        XCTAssertEqual(back.labels["k"], "v")
        XCTAssertEqual(back.fastBoot, true)
        XCTAssertEqual(back.created.timeIntervalSince1970, spec.created.timeIntervalSince1970, accuracy: 0.002)
    }

    func testLegacySecondPrecisionDatesStillDecode() throws {
        let d = try JSON.decoder.decode([String: Date].self, from: Data(#"{"a":"2026-01-02T03:04:05Z"}"#.utf8))
        XCTAssertNotNil(d["a"])
    }

    func testProfilesHaveNoArtificialCapsAndKeepHostHeadroom() {
        let host = HostInfo(cpuCount: 24, performanceCores: 16, memoryMiB: 131072, onBattery: false, batteryPercent: nil,
                            lowPowerMode: false, thermalState: "nominal", osVersion: "", maxVMCPUs: 64,
                            maxVMMemoryMiB: 131072, rosettaAvailable: true)
        let dev = ProfileEngine.resources(for: .development, os: .linux, host: host)
        XCTAssertGreaterThan(dev.cpus, 4, "no 4-vCPU edition cap")
        XCTAssertGreaterThan(dev.memoryMiB, 8192, "no 8 GB edition cap")
        XCTAssertLessThanOrEqual(dev.memoryMiB, 131072 - 32768, "host keeps >= 25% RAM")
        let travel = ProfileEngine.resources(for: .travel, os: .linux, host: host)
        XCTAssertEqual(travel.cpus, 2)
    }

    func testTravelModeKicksInOnLowBattery() {
        var host = HostInfo.current()
        host.onBattery = true
        host.batteryPercent = 15
        XCTAssertEqual(ProfileEngine.effectiveProfile(requested: .gaming, host: host), .travel)
        host.onBattery = false
        XCTAssertEqual(ProfileEngine.effectiveProfile(requested: .gaming, host: host), .gaming)
    }

    func testNameValidation() {
        XCTAssertNoThrow(try VMLibrary.validateName("dev-box_1.2"))
        XCTAssertThrowsError(try VMLibrary.validateName("../etc"))
        XCTAssertThrowsError(try VMLibrary.validateName(""))
    }

    func testMACAddressIsLocallyAdministeredUnicast() {
        for _ in 0..<50 {
            let first = UInt8(MACAddress.random().prefix(2), radix: 16)!
            XCTAssertEqual(first & 0x03, 0x02)
        }
    }
}

final class PolicyAndSigningTests: IsolatedHomeTestCase {
    func testViolationsAndRemediation() {
        var p = Policy(organization: "Acme")
        p.maxCPUs = 4
        p.allowMicrophone = false
        p.requireIsolation = true
        var spec = VMSpec.defaults(name: "x", os: .linux)
        spec.cpus = 8
        spec.integration.microphone = true
        let v = p.violations(spec)
        XCTAssertTrue(v.contains { $0.contains("cpus") })
        XCTAssertTrue(v.contains { $0.contains("microphone") })
        XCTAssertTrue(v.contains { $0.contains("isolated") })
        p.remediate(&spec)
        XCTAssertTrue(p.violations(spec).isEmpty, "\(p.violations(spec))")
    }

    func testSignedPolicyVerifiesAndTamperFailsClosed() throws {
        let kp = Signing.generate()
        let (priv, pub) = try Signing.writeKeyPair(kp, to: home, name: "it")
        try FileManager.default.copyItem(at: pub, to: Paths.trustedKeys.appendingPathComponent("it.pub"))
        var p = Policy(organization: "Acme")
        p.maxCPUs = 2
        let signed = try p.sign(with: priv)
        XCTAssertEqual(try Policy.verify(signed).maxCPUs, 2)
        try Policy.install(signed)
        XCTAssertEqual(Policy.loadActive()?.organization, "Acme")

        // Tamper with the payload: must become LOCKDOWN, never "no policy".
        var bad = signed
        var obj = try JSONSerialization.jsonObject(with: Data(base64Encoded: bad.payload)!) as! [String: Any]
        obj["maxCPUs"] = 64
        bad.payload = try JSONSerialization.data(withJSONObject: obj).base64EncodedString()
        try JSON.encoder.encode(bad).write(to: Paths.policy)
        let active = Policy.loadActive()
        XCTAssertEqual(active?.organization, "LOCKDOWN")
        XCTAssertEqual(active?.maxVMs, 0)
    }

    func testUntrustedSignerRejected() throws {
        let (priv, _) = try Signing.writeKeyPair(Signing.generate(), to: home, name: "rogue")
        let signed = try Policy(organization: "Evil").sign(with: priv)
        XCTAssertThrowsError(try Policy.verify(signed))
    }

    func testEscrowSealAndRecover() throws {
        let k = EncryptedStore.generateEscrowKey()
        let blob = try EncryptedStore.sealEscrow("s3cret passphrase", to: k.publicKey)
        try blob.write(to: EncryptedStore.escrow("vm1"))
        XCTAssertEqual(try EncryptedStore.recover("vm1", escrowPrivateKey: k.privateKey), "s3cret passphrase")
        let other = EncryptedStore.generateEscrowKey()
        XCTAssertThrowsError(try EncryptedStore.recover("vm1", escrowPrivateKey: other.privateKey))
    }
}

final class AuditTests: IsolatedHomeTestCase {
    func testChainIntactAndDetectsEditsAndDeletions() throws {
        let log = AuditLog(url: home.appendingPathComponent("a.jsonl"))
        for i in 0..<10 { log.record("evt.\(i)", vm: "vm", details: ["i": "\(i)", "tricky": #"quote " and "hash":"""#]) }
        XCTAssertNil(log.verify())
        XCTAssertEqual(log.entries().count, 10)

        let original = try String(contentsOf: log.url, encoding: .utf8)
        try original.replacingOccurrences(of: "evt.3", with: "evt.X").write(to: log.url, atomically: true, encoding: .utf8)
        XCTAssertNotNil(log.verify())

        var lines = original.split(separator: "\n")
        lines.remove(at: 5)
        try (lines.joined(separator: "\n") + "\n").write(to: log.url, atomically: true, encoding: .utf8)
        XCTAssertNotNil(log.verify())

        try original.write(to: log.url, atomically: true, encoding: .utf8)
        XCTAssertNil(log.verify())
    }
}

final class DHCPTests: XCTestCase {
    func discover(mac: [UInt8], type: UInt8) -> Data {
        var bootp = [UInt8](repeating: 0, count: 240)
        bootp[0] = 1; bootp[1] = 1; bootp[2] = 6
        bootp[4] = 0xDE; bootp[5] = 0xAD; bootp[6] = 0xBE; bootp[7] = 0xEF
        for i in 0..<6 { bootp[28 + i] = mac[i] }
        bootp[236] = 99; bootp[237] = 130; bootp[238] = 83; bootp[239] = 99
        bootp += [53, 1, type, 255]
        let udpLen = 8 + bootp.count
        let udp: [UInt8] = [0, 68, 0, 67, UInt8(udpLen >> 8), UInt8(udpLen & 0xFF), 0, 0]
        let ip: [UInt8] = [0x45, 0, 0, 0, 0, 0, 0, 0, 64, 17, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255]
        let eth: [UInt8] = [255, 255, 255, 255, 255, 255] + mac + [0x08, 0x00]
        return Data(eth + ip + udp + bootp)
    }

    func testOfferAckAndStableLeases() throws {
        var leases: [Data: UInt8] = [:]
        let mac: [UInt8] = [0x02, 1, 2, 3, 4, 5]
        let offer = try XCTUnwrap(DHCPServer.reply(to: discover(mac: mac, type: 1), subnet: "10.77.5", leases: &leases))
        let o = [UInt8](offer)
        let bootp = 14 + 20 + 8
        XCTAssertEqual(Array(o[(bootp + 16)..<(bootp + 20)]), [10, 77, 5, 10], "yiaddr")
        XCTAssertEqual(Array(o[(bootp + 4)..<(bootp + 8)]), [0xDE, 0xAD, 0xBE, 0xEF], "xid echoed")
        XCTAssertEqual(o[bootp + 242], 2, "OFFER")
        let ack = try XCTUnwrap(DHCPServer.reply(to: discover(mac: mac, type: 3), subnet: "10.77.5", leases: &leases))
        XCTAssertEqual([UInt8](ack)[bootp + 242], 5, "ACK")
        XCTAssertEqual(leases.count, 1, "same MAC keeps its lease")
        _ = DHCPServer.reply(to: discover(mac: [0x02, 9, 9, 9, 9, 9], type: 1), subnet: "10.77.5", leases: &leases)
        XCTAssertEqual(Set(leases.values), [10, 11])
        // IPv4 header checksum must validate to zero.
        XCTAssertEqual(DHCPServer.checksum(Array(o[14..<34])), 0)
    }

    func testIgnoresNonDHCP() {
        var leases: [Data: UInt8] = [:]
        XCTAssertNil(DHCPServer.reply(to: Data(repeating: 0, count: 400), subnet: "10.0.0", leases: &leases))
    }
}

final class DiskAndImageTests: IsolatedHomeTestCase {
    func testQCOW2ConversionWithPlainZeroAndCompressedClusters() throws {
        let clusterBits = 16, cs = 1 << clusterBits
        let size: UInt64 = UInt64(cs) * 4
        var f = Data(count: cs * 6)
        func put64(_ off: Int, _ v: UInt64) { for i in 0..<8 { f[off + i] = UInt8((v >> (56 - 8 * UInt64(i))) & 0xFF) } }
        func put32(_ off: Int, _ v: UInt32) { for i in 0..<4 { f[off + i] = UInt8((v >> (24 - 8 * UInt32(i))) & 0xFF) } }
        put32(0, 0x514649FB); put32(4, 3); put32(20, UInt32(clusterBits)); put64(24, size)
        put32(36, 1); put64(40, UInt64(cs))           // L1 at cluster 1, one entry
        put32(100, 104)                                // header length
        put64(cs, UInt64(2 * cs) | (1 << 63))          // L1[0] → L2 at cluster 2
        // guest cluster 0: plain data at host cluster 3
        put64(2 * cs + 0, UInt64(3 * cs) | (1 << 63))
        for i in 0..<cs { f[3 * cs + i] = UInt8(i % 251) }
        // guest cluster 1: zero flag
        put64(2 * cs + 8, 1)
        // guest cluster 2: compressed (raw deflate) at host cluster 4
        let plain = [UInt8](repeating: 0x5A, count: cs)
        var comp = [UInt8](repeating: 0, count: cs)
        let clen = compression_encode_buffer(&comp, cs, plain, cs, nil, COMPRESSION_ZLIB)
        XCTAssertGreaterThan(clen, 0)
        for i in 0..<clen { f[4 * cs + i] = comp[i] }
        let x = 62 - (clusterBits - 8)
        let sectors = UInt64((clen + 511) / 512) - 1
        put64(2 * cs + 16, (1 << 62) | (sectors << UInt64(x)) | UInt64(4 * cs))
        let src = home.appendingPathComponent("t.qcow2"), dst = home.appendingPathComponent("t.raw")
        try f.write(to: src)
        XCTAssertTrue(QCOW2.isQCOW2(src))
        try QCOW2.convert(src, to: dst)
        let out = try Data(contentsOf: dst)
        XCTAssertEqual(UInt64(out.count), size)
        XCTAssertEqual(out[0..<cs], Data((0..<cs).map { UInt8($0 % 251) }))
        XCTAssertTrue(out[cs..<(2 * cs)].allSatisfy { $0 == 0 })
        XCTAssertTrue(out[(2 * cs)..<(3 * cs)].allSatisfy { $0 == 0x5A })
        XCTAssertTrue(out[(3 * cs)...].allSatisfy { $0 == 0 })
    }

    func testCloneIsInstantAndIndependent() throws {
        var spec = VMSpec.defaults(name: "src", os: .linux, diskGiB: 2)
        spec.integration.sharedFolders = []
        let b = try VMLibrary.create(spec: spec, policy: nil)
        let disk = b.url.appendingPathComponent("disk0.img")
        let fh = try FileHandle(forWritingTo: disk); try fh.write(contentsOf: Data(repeating: 7, count: 4096)); try fh.close()
        let c = try VMLibrary.clone("src", to: "dst")
        let cspec = try c.loadSpec()
        XCTAssertNotEqual(cspec.network.first?.macAddress, spec.network.first?.macAddress)
        XCTAssertEqual(cspec.labels["clonedFrom"], "src")
        let fh2 = try FileHandle(forWritingTo: c.url.appendingPathComponent("disk0.img")); try fh2.write(contentsOf: Data(repeating: 9, count: 4096)); try fh2.close()
        XCTAssertEqual(try Data(contentsOf: disk).prefix(1), Data([7]), "source unaffected by clone writes")
    }

    func testSnapshotsCreateRestoreDeleteAndTree() throws {
        var spec = VMSpec.defaults(name: "s", os: .linux, diskGiB: 1)
        spec.integration.sharedFolders = []
        let b = try VMLibrary.create(spec: spec, policy: nil)
        let disk = b.url.appendingPathComponent("disk0.img")
        func write(_ byte: UInt8) throws { let h = try FileHandle(forWritingTo: disk); try h.write(contentsOf: Data([byte])); try h.close() }
        func read() throws -> UInt8 { try Data(contentsOf: disk)[0] }
        let sm = SnapshotManager(bundle: b)
        try write(1); let a = try sm.create(name: "a")
        try write(2); let s2 = try sm.create(name: "b")
        XCTAssertEqual(s2.parent, a.id)
        try write(3)
        try sm.restore("a"); XCTAssertEqual(try read(), 1)
        try sm.restore(s2.id); XCTAssertEqual(try read(), 2)
        XCTAssertTrue(sm.tree().contains("← current"))
        try sm.delete("a")
        XCTAssertNil(try sm.find("b").parent, "child re-parented")
    }

    func testGoldenImageRoundTripSparseAndTamperDetection() throws {
        var spec = VMSpec.defaults(name: "gold", os: .linux, diskGiB: 4)
        spec.integration.sharedFolders = []
        let b = try VMLibrary.create(spec: spec, policy: nil)
        let disk = b.url.appendingPathComponent("disk0.img")
        let h = try FileHandle(forWritingTo: disk)
        try h.seek(toOffset: 3 << 30); try h.write(contentsOf: Data("hello at 3GiB".utf8)); try h.close()
        let (priv, pub) = try Signing.writeKeyPair(Signing.generate(), to: home, name: "img")
        try FileManager.default.copyItem(at: pub, to: Paths.trustedKeys.appendingPathComponent("img.pub"))
        let img = home.appendingPathComponent("gold.avmimg")
        let m = try GoldenImage.pack(vm: "gold", to: img, version: "1", signingKey: priv)
        XCTAssertLessThan(DiskManager.logicalSize(img), 1 << 20, "4 GiB sparse disk packs to < 1 MiB")
        let ins = try GoldenImage.inspect(img)
        XCTAssertTrue(ins.signed && ins.trusted)
        let d = try GoldenImage.deploy(img, as: "copy")
        let out = d.url.appendingPathComponent("disk0.img")
        XCTAssertEqual(DiskManager.logicalSize(out), 4 << 30)
        XCTAssertLessThan(DiskManager.allocated(out), 64 << 20, "deployed disk stays sparse")
        let rh = try FileHandle(forReadingFrom: out); try rh.seek(toOffset: 3 << 30)
        XCTAssertEqual(try rh.read(upToCount: 13), Data("hello at 3GiB".utf8)); try rh.close()
        XCTAssertEqual(try d.loadSpec().labels["image"], "gold@\(m.version)")

        var bytes = try Data(contentsOf: img)
        bytes[20] ^= 0xFF
        let bad = home.appendingPathComponent("bad.avmimg"); try bytes.write(to: bad)
        XCTAssertThrowsError(try GoldenImage.deploy(bad, as: "evil"))
        XCTAssertThrowsError(try VMLibrary.find("evil"))
    }

    func testCloudInitUserDataIncludesAgentUserAndKeys() {
        var o = CreateOptions(name: "ci")
        o.username = "alice"
        o.sshKeys = ["ssh-ed25519 AAAA test"]
        let spec = VMSpec.defaults(name: "ci", os: .linux)
        let ud = CloudInit.userData(spec: spec, options: o)
        XCTAssertTrue(ud.hasPrefix("#cloud-config"))
        XCTAssertTrue(ud.contains("alice"))
        XCTAssertTrue(ud.contains("ssh-ed25519 AAAA test"))
        XCTAssertTrue(ud.contains("altvm-agent.service"))
        XCTAssertTrue(ud.contains("lock_passwd: true"))
    }
}

final class APITests: IsolatedHomeTestCase {
    func req(_ method: String, _ path: String, token: String?) -> APIServer.Request {
        APIServer.Request(method: method, path: path, query: [:],
                          headers: token.map { ["authorization": "Bearer \($0)"] } ?? [:], body: Data())
    }

    func testAuthRoutingAndErrors() throws {
        let s = APIServer(port: 1, token: String(repeating: "a", count: 64))
        XCTAssertEqual(s.handle(req("GET", "/api/v1/vms", token: nil)).status, 401)
        XCTAssertEqual(s.handle(req("GET", "/api/v1/vms", token: "wrong")).status, 401)
        XCTAssertEqual(s.handle(req("GET", "/api/v1/vms", token: String(repeating: "a", count: 64))).status, 200)
        XCTAssertEqual(s.handle(req("GET", "/api/v1/vms/missing", token: String(repeating: "a", count: 64))).status, 404)
        XCTAssertEqual(s.handle(req("GET", "/", token: nil)).status, 200, "portal shell is public; data is not")
        XCTAssertEqual(s.handle(req("GET", "/metrics", token: nil)).status, 401)
    }

    func testFleetPlanIsIdempotentShape() {
        var d = DesiredVM(name: "new", from: "blank")
        d.state = "running"
        let plan = Fleet.plan(FleetFile(organization: nil, vms: [d]))
        XCTAssertEqual(plan.map(\.kind), ["create", "start"])
    }
}

final class AutomationTests: IsolatedHomeTestCase {
    func testKeysymMappingMatchesMeasuredServerBehaviour() {
        // Measured: Alt_L → GUI (⌘/Win/Super); Meta_L → Alt (⌥); Super_* ignored by the server.
        XCTAssertEqual(Keysym.named("cmd"), 0xFFE9)
        XCTAssertEqual(Keysym.named("super"), 0xFFE9)
        XCTAssertEqual(Keysym.named("win"), 0xFFE9)
        XCTAssertEqual(Keysym.named("alt"), 0xFFE7)
        XCTAssertEqual(Keysym.named("option"), 0xFFE7)
        XCTAssertEqual(Keysym.named("Return"), 0xFF0D)
        XCTAssertEqual(Keysym.named("F5"), 0xFFC2)
        XCTAssertEqual(Keysym.named("page_down"), 0xFF56)
        XCTAssertTrue(Keysym.forCharacter("A").1, "uppercase needs shift")
        XCTAssertTrue(Keysym.forCharacter("@").1)
        XCTAssertFalse(Keysym.forCharacter("a").1)
        XCTAssertEqual(Keysym.forCharacter("é").0, 0xE9)
        XCTAssertEqual(Keysym.forCharacter("€").0, 0x0100_0000 + 0x20AC)
    }

    func testVNCAuthIsDeterministicDESOfChallenge() {
        let ch = [UInt8](repeating: 7, count: 16)
        let a = RFBClient.vncAuthResponse(challenge: ch, password: "secret12")
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a, RFBClient.vncAuthResponse(challenge: ch, password: "secret12"))
        XCTAssertNotEqual(a, RFBClient.vncAuthResponse(challenge: ch, password: "secret13"))
        XCTAssertNotEqual(Array(a[0..<8]), Array(ch[0..<8]))
    }

    func testMCPToolScoping() throws {
        let s = MCPServer()
        s.allowedVMs = ["a"]
        s.allowLifecycle = false
        XCTAssertThrowsError(try s.call("vm_info", ["name": "b"]))
        XCTAssertThrowsError(try s.call("delete_vm", ["name": "a"]))
        XCTAssertNoThrow(try s.call("list_vms", [:]))
    }
}

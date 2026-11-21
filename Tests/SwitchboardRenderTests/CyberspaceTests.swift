import Foundation
import SwitchboardCore
import Testing
import simd

@testable import SwitchboardRender

@Suite struct AddressFloorTests {
    @Test func theCurveVisitsEveryCellOnceAndStepsToANeighbour() {
        var seen = Set<SIMD2<UInt32>>()
        var previous: (x: UInt32, y: UInt32)?
        for index in 0..<256 {
            let cell = AddressFloor.hilbert(UInt64(index), order: 4)
            seen.insert(SIMD2(cell.x, cell.y))
            if let previous {
                let step = abs(Int(cell.x) - Int(previous.x)) + abs(Int(cell.y) - Int(previous.y))
                #expect(step == 1, "\(index)")
            }
            previous = cell
        }
        #expect(seen.count == 256)
    }

    @Test func everyPrefixIsOneBlockOfFloor() {
        // The cell a whole address lands in, seen at 16 × 16, is the cell of its /8.
        var value: UInt32 = 0x9E37_79B9
        for _ in 0..<2000 {
            value = value &* 1_664_525 &+ 1_013_904_223
            let fine = AddressFloor.hilbert(UInt64(value), order: 16)
            let coarse = AddressFloor.hilbert(UInt64(value >> 24), order: 4)
            #expect(fine.x >> 12 == coarse.x && fine.y >> 12 == coarse.y)
        }
        // A /16 is a block a 256th of the square across.
        let a = AddressFloor.place(IPAddress("52.1.0.0")!).point, b = AddressFloor.place(IPAddress("52.1.255.255")!).point
        #expect(abs(a.x - b.x) < AddressFloor.side / 256 + 0.01 && abs(a.y - b.y) < AddressFloor.side / 256 + 0.01)
        #expect(AddressFloor.blockName(IPAddress("52.1.2.3")!) == "52/8")
        #expect(AddressFloor.blockName(IPAddress("2606:4700::1111")!) == "2600::/11")
    }

    @Test func eachFamilyHasItsOwnSquare() {
        func inside(_ point: SIMD2<Float>, _ center: SIMD2<Float>) -> Bool {
            abs(point.x - center.x) <= AddressFloor.side / 2 && abs(point.y - center.y) <= AddressFloor.side / 2
        }
        for text in ["0.0.0.0", "8.8.8.8", "10.1.2.3", "192.168.1.20", "255.255.255.255"] {
            let place = AddressFloor.place(IPAddress(text)!)
            #expect(place.square == .v4 && inside(place.point, AddressFloor.v4Center), "\(text)")
        }
        for text in ["2001:db8::1", "2606:4700::1111", "3fff:ffff::1"] {
            let place = AddressFloor.place(IPAddress(text)!)
            #expect(place.square == .v6 && inside(place.point, AddressFloor.v6Center), "\(text)")
        }
        // An IPv4-mapped address stands where its IPv4 address does.
        #expect(AddressFloor.place(IPAddress("::ffff:8.8.8.8")!).point == AddressFloor.place(IPAddress("8.8.8.8")!).point)
        // Addresses with no place on either square stand in the gap between them.
        for text in ["fe80::1", "fd00::5", "::1"] {
            let place = AddressFloor.place(IPAddress(text)!)
            #expect(place.square == .local && abs(place.point.x) <= AddressFloor.gap / 2, "\(text)")
        }
    }
}

private func seen(_ id: UInt64, pid: Int32, remote: String, bytes: UInt64) -> SourceEvent {
    let local = remote.contains(":") ? "2001:db8::2" : "10.0.0.2"
    return .seen(SocketObservation(
        sourceID: id, proto: .tcp, local: Endpoint(address: IPAddress(local)!, port: UInt16(40_000 + id)),
        remote: Endpoint(address: IPAddress(remote)!, port: 443), pid: pid, processName: "app\(pid)",
        rxBytes: bytes, txBytes: bytes / 10, tcpState: .established))
}

private func space() -> GraphController {
    let engine = FlowEngine()
    engine.ingest([
        seen(1, pid: 1, remote: "8.8.8.8", bytes: 50_000), seen(2, pid: 1, remote: "1.1.1.1", bytes: 50_000_000),
        seen(3, pid: 2, remote: "2606:4700::1111", bytes: 500_000), seen(4, pid: 2, remote: "fe80::1", bytes: 5_000),
    ], from: "test", at: 0)
    let controller = GraphController()
    controller.layout = .cyberspace
    controller.clustering = .off
    controller.update(engine.snapshot(), time: 0)
    controller.settle()
    return controller
}

@Suite struct CyberspaceTests {
    @Test func towersStandOnTheirAddressesAsTallAsTheirBytes() throws {
        let controller = space()
        for text in ["8.8.8.8", "1.1.1.1", "2606:4700::1111", "fe80::1"] {
            let address = IPAddress(text)!
            let top = try #require(controller.spacePoint(of: .endpoint(address)), "\(text)")
            let floor = AddressFloor.place(address).point
            #expect(simd_distance(SIMD2(top.x, top.z), floor) <= 4.01, "\(text)")
            #expect(top.y > 0)
        }
        let small = try #require(controller.spacePoint(of: .endpoint(IPAddress("8.8.8.8")!)))
        let large = try #require(controller.spacePoint(of: .endpoint(IPAddress("1.1.1.1")!)))
        #expect(large.y > small.y + 100)
        // This Mac floats over the gap, its processes in a ring below it.
        #expect(controller.spacePoint(of: .host) == SIMD3(0, GraphController.hostHeight, 0))
        let process = try #require(controller.spacePoint(of: .process(1)))
        #expect(process.y == GraphController.processHeight)
        #expect(simd_length(SIMD2(process.x, process.z)) >= 560)
        // Beams join processes to towers, and are found by connection.
        let beam = PickTarget.edge(.process(1), .endpoint(IPAddress("1.1.1.1")!))
        #expect(controller.flows(for: beam).count == 1)
        #expect(controller.target(pid: 1, remote: Endpoint(address: IPAddress("1.1.1.1")!, port: 443), proto: .tcp) == beam)
        // No flat graph paper behind a floor of its own.
        #expect(!controller.frame(labelBudget: 0).flatGrid)
    }

    @Test func orbitsSlowlyOnItsOwnAndNotInStill() {
        let controller = space()
        controller.advance(time: 10)
        controller.advance(time: 40)
        let turned = controller.spaceCameraNow.yaw - SpaceCamera.homeYaw
        #expect(abs(turned - 30 * 2 * .pi / 300) < 1e-3)
        let still = space()
        still.advance(time: 10, motion: false)
        still.advance(time: 40, motion: false)
        #expect(still.spaceCameraNow == SpaceCamera())
    }

    @Test func dragOrbitsAndStaysThenResetGoesHome() throws {
        let controller = space()
        let tower = NodeID.endpoint(IPAddress("1.1.1.1")!)
        func onScreen() -> SIMD2<Float>? {
            controller.frame(labelBudget: 0).nodes.first { controller.pick(at: $0.center, slack: 0.5) == .node(tower) }?.center
        }
        let before = try #require(onScreen())
        controller.orbitSpace(by: SIMD2(260, 0))
        controller.settle()
        #expect(controller.spaceIsTurnedByHand)
        #expect(abs(controller.spaceCameraNow.yaw - (SpaceCamera.homeYaw - 0.5)) < 1e-4)
        let after = try #require(onScreen())
        #expect(simd_distance(before, after) > 20)
        // Left alone it does not orbit on.
        controller.advance(time: 0)
        controller.advance(time: 30)
        #expect(abs(controller.spaceCameraNow.yaw - (SpaceCamera.homeYaw - 0.5)) < 1e-4)
        // Pitch is held between grazing the floor and looking straight down.
        controller.orbitSpace(by: SIMD2(0, -100_000))
        #expect(controller.spaceCameraNow.pitch <= 1.5)
        controller.resetSpace()
        #expect(!controller.spaceIsTurnedByHand)
        #expect(controller.spaceCameraNow == SpaceCamera())
    }

    @Test func fliesAcrossTheFloorWhileKeysAreHeldAndToATower() throws {
        let controller = space()
        let start = controller.spaceCameraNow
        controller.flySpace(SIMD3(0, 0, 1))
        controller.advance(time: 0)
        for tick in 1...10 { controller.advance(time: Float(tick) * 0.05) }
        controller.flySpace(.zero)
        let moved = controller.spaceCameraNow.target - start.target
        let ahead = SIMD3<Float>(-sin(start.yaw), 0, -cos(start.yaw))
        #expect(simd_dot(moved, ahead) > 100)
        #expect(controller.spaceIsTurnedByHand)
        let stopped = controller.spaceCameraNow.target
        controller.advance(time: 1)
        #expect(controller.spaceCameraNow.target == stopped)

        // Double-clicking a tower glides there and comes in closer.
        let tower = try #require(controller.spacePoint(of: .endpoint(IPAddress("1.1.1.1")!)))
        controller.flyTo(.endpoint(IPAddress("1.1.1.1")!))
        for tick in 1...120 { controller.advance(time: 1 + Float(tick) * 0.05) }
        let camera = controller.spaceCameraNow
        #expect(simd_distance(SIMD2(camera.target.x, camera.target.z), SIMD2(tower.x, tower.z)) < 5)
        #expect(camera.distance <= 1301)
    }

    @Test func dollyStaysWithinReach() {
        let controller = space()
        controller.dollySpace(by: 1000)
        #expect(controller.spaceCameraNow.distance == 250)
        controller.dollySpace(by: 0.0001)
        #expect(controller.spaceCameraNow.distance == 14_000)
    }

    @Test func whatIsBehindTheCameraIsNotDrawn() {
        let camera = SpaceCamera()
        let basis = camera.basis()
        #expect(SpaceCamera.project(camera.target, basis) != nil)
        let behind = camera.eye - basis.forward * 100
        #expect(SpaceCamera.project(behind, basis) == nil)
        #expect(SpaceCamera.project(behind, behind + basis.right * 50, basis) == nil)
        // A line from behind to in front is cut where it passes the camera.
        let cut = SpaceCamera.project(behind, camera.target, basis)
        #expect(cut != nil)
        if let cut { #expect(cut.0.x.isFinite && cut.0.y.isFinite && cut.2 > SpaceCamera.near) }
        // Far things fade; things at the target are in full view.
        #expect(SpaceCamera.fog(camera.distance) > 0.9)
        #expect(SpaceCamera.fog(SpaceCamera.fogEnd) == 0)
    }
}

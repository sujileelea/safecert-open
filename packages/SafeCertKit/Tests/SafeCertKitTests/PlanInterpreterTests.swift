import Foundation
import Testing
@testable import SafeCertKit

@Suite("평면 해석")
struct PlanInterpreterTests {
    func model(_ plan: SamplePlan) throws -> PlanModel {
        PlanInterpreter.interpret(try VectorPDF.read(SamplePlanRenderer.pdf(for: plan)))
    }

    @Test func sampleA() throws {
        let plan = SamplePlan.compliant
        let m = try model(plan)
        let k = plan.pointsPerMeter
        let boundary = try #require(m.boundary)
        #expect(abs(boundary.area / (k * k) - 160) < 2, "영업장 면적 \(boundary.area / (k * k))㎡")
        #expect(m.boundaryConfidence >= 0.9)
        #expect(m.doors.count == 4)
        #expect(m.exteriorDoors.count == 2)

        let main = try #require(m.mainEntrances.first)
        #expect(main.label == "주출입구")
        #expect(main.tag == DoorTag(raw: "W1200×H2100", widthMM: 1200, heightMM: 2100))
        #expect(abs(main.openingWidth / k - 1.2) < 0.05)
        #expect(main.swingsOutward == true)

        let exit = try #require(m.emergencyExits.first)
        #expect(exit.label == "비상구")
        #expect(exit.tag?.widthMM == 900)
        #expect(abs(exit.openingWidth / k - 0.9) < 0.05)

        #expect(Set(m.rooms.compactMap(\.label)) == ["룸1", "주방"])
        #expect(m.hall?.label == "홀")
    }

    @Test func sampleB() throws {
        let plan = SamplePlan.risky
        let m = try model(plan)
        let k = plan.pointsPerMeter
        #expect(m.rooms.count == 4)
        let exit = try #require(m.emergencyExits.first)
        #expect(abs(exit.openingWidth / k - 0.7) < 0.05)
        #expect(exit.tag == nil)
        #expect(m.mainEntrances.count == 1)
    }

    @Test func sampleC() throws {
        let plan = SamplePlan.noExit
        let m = try model(plan)
        let k = plan.pointsPerMeter
        #expect(m.rooms.isEmpty)
        #expect(m.emergencyExits.isEmpty)
        #expect(m.mainEntrances.count == 1)
        #expect(abs((m.boundary?.area ?? 0) / (k * k) - 30) < 1)
    }

    @Test func parsesDoorTags() {
        #expect(PlanInterpreter.parseTag("W900×H2100")?.widthMM == 900)
        #expect(PlanInterpreter.parseTag("900x2,100")?.heightMM == 2100)
        #expect(PlanInterpreter.parseTag("W 750 X H 1500")?.widthMM == 750)
        #expect(PlanInterpreter.parseTag("주방") == nil)
    }
}

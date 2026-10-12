import Foundation

/// 문 역할. 법령 용어: 주된 출입구 · 비상구(별표 1의2 비고 2).
public enum DoorRole: String, Codable, Sendable, CaseIterable {
    case mainEntrance
    case emergencyExit
    case interior
    case unknownExterior

    public var displayName: String {
        switch self {
        case .mainEntrance: "주된 출입구"
        case .emergencyExit: "비상구"
        case .interior: "실 출입문"
        case .unknownExterior: "외부 출입문(역할 미상)"
        }
    }

    public var isExterior: Bool { self != .interior }
}

/// 도면에 적힌 문 규격(mm).
public struct DoorTag: Hashable, Codable, Sendable {
    public var raw: String
    public var widthMM: Int
    public var heightMM: Int
}

public struct DoorObject: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    /// 경첩(원호 중심).
    public var hinge: Point
    /// 닫힌 문짝 끝(개구부 반대쪽 끝).
    public var closedEnd: Point
    /// 열린 문짝 끝.
    public var openEnd: Point
    public var radius: Double
    public var role: DoorRole
    /// 역할 판정 신뢰도(0~1). 표기로 확인되면 0.95.
    public var roleConfidence: Double
    public var label: String?
    public var tag: DoorTag?
    /// 영업장 밖으로 열리는가(외부 문만 의미 있음).
    public var swingsOutward: Bool?

    public var chord: Segment { Segment(hinge, closedEnd) }
    public var center: Point { chord.midpoint }
    /// 도면상 개구부 폭(포인트) = 문짝 길이.
    public var openingWidth: Double { chord.length }
}

public struct RoomObject: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var polygon: Polygon
    public var label: String?
}

/// 평면도 해석 결과. 좌표·길이는 PDF 포인트(축척 적용 전).
public struct PlanModel: Hashable, Codable, Sendable {
    public var pageWidth: Double
    public var pageHeight: Double
    /// 영업장 외곽선.
    public var boundary: Polygon?
    public var boundaryConfidence: Double
    /// 영업장 안의 면 중 가장 큰 면(홀)을 뺀 나머지 = 구획된 실.
    public var rooms: [RoomObject]
    public var hall: RoomObject?
    public var doors: [DoorObject]
    public var wallSegments: [Segment]
    public var texts: [TextRun]
    public var notes: [String]

    public var exteriorDoors: [DoorObject] { doors.filter { $0.role.isExterior } }
    public var mainEntrances: [DoorObject] { doors.filter { $0.role == .mainEntrance } }
    public var emergencyExits: [DoorObject] { doors.filter { $0.role == .emergencyExit } }
}

import Foundation

public enum Tri: String, Codable, Sendable, CaseIterable {
    case yes, no, unknown

    public var displayName: String {
        switch self {
        case .yes: "예"
        case .no: "아니오"
        case .unknown: "모름"
        }
    }
}

/// 다중이용업 업종(고시 적용 구분에 필요한 만큼만).
public enum BusinessType: String, Codable, Sendable, CaseIterable {
    case restaurant
    case karaoke
    case pcRoom
    case gosiwon
    case shootingGolfMassage
    case other

    public var displayName: String {
        switch self {
        case .restaurant: "일반·휴게음식점"
        case .karaoke: "노래연습장"
        case .pcRoom: "인터넷컴퓨터게임시설(PC방)"
        case .gosiwon: "고시원"
        case .shootingGolfMassage: "옥내권총사격장·골프연습장·안마시술소"
        case .other: "그 밖의 다중이용업"
        }
    }
}

/// 사용자 입력 조건(U-02). 도면에 없는 값이다.
public struct Conditions: Hashable, Codable, Sendable {
    public var isMultiUseBusiness: Bool
    public var businessType: BusinessType
    /// 영업장이 피난층(지상 1층 등)에 있는가.
    public var isEvacuationFloor: Tri
    /// 2010-11-11 이전부터 영업 중인 기존 다중이용업소인가.
    public var isExistingBusiness: Tri
    /// 주된 출입구 외에 영업장 내부에서 피난층·지상으로 통하는 직통계단이 따로 있는가.
    public var hasSeparateDirectStair: Tri

    public init(isMultiUseBusiness: Bool = true, businessType: BusinessType = .restaurant, isEvacuationFloor: Tri = .unknown,
                isExistingBusiness: Tri = .no, hasSeparateDirectStair: Tri = .no) {
        self.isMultiUseBusiness = isMultiUseBusiness
        self.businessType = businessType
        self.isEvacuationFloor = isEvacuationFloor
        self.isExistingBusiness = isExistingBusiness
        self.hasSeparateDirectStair = hasSeparateDirectStair
    }
}

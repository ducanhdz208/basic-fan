import Foundation
let helperServiceName = "local.basicfan.helper"
@objc protocol FanHelperProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func update(mode: String, percent: Double, rpm: Double, suspended: Bool, withReply reply: @escaping (String) -> Void)
}

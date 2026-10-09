//
//  smc.swift
//  SMC
//
//  Created by Serhiy Mytrovtsiy on 25/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import IOKit

internal enum SMCDataType: String {
    case UI8 = "ui8 "
    case UI16 = "ui16"
    case UI32 = "ui32"
    case SP1E = "sp1e"
    case SP3C = "sp3c"
    case SP4B = "sp4b"
    case SP5A = "sp5a"
    case SPA5 = "spa5"
    case SP69 = "sp69"
    case SP78 = "sp78"
    case SP87 = "sp87"
    case SP96 = "sp96"
    case SPB4 = "spb4"
    case SPF0 = "spf0"
    case FLT = "flt "
    case FPE2 = "fpe2"
    case FP2E = "fp2e"
    case FDS = "{fds"
}

internal enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
    case auto3 = 3

    public var isAutomatic: Bool {
        self == .automatic || self == .auto3
    }
}

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)
    
    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    
    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    
    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    
    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}

internal struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
    
    init(_ key: String) {
        self.key = key
    }
}

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)
        
        self = str.utf8.reduce(0) { sum, character in
            return sum << 8 | UInt32(character)
        }
    }
    
    func toString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
               String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

extension UInt16 {
    init(bytes: (UInt8, UInt8)) {
        self = UInt16(bytes.0) << 8 | UInt16(bytes.1)
    }
}

extension UInt32 {
    init(bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }
}

extension Int {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }
}

extension Float {
    init?(_ bytes: [UInt8]) {
        self = bytes.withUnsafeBytes {
            return $0.loadUnaligned(fromByteOffset: 0, as: Self.self)
        }
    }
    
    var bytes: [UInt8] {
        withUnsafeBytes(of: self, Array.init)
    }
}

public class SMC {
    public static let shared = SMC()
    private var conn: io_connect_t = 0
    private var _fanModeKeyIsLower: Bool?
    private let keyInfoLock = NSLock()
    private var keyInfoCache: [UInt32: SMCKeyData_t.keyInfo_t] = [:]
    
    public init() {
        var result: kern_return_t
        var iterator: io_iterator_t = 0
        let device: io_object_t
        
        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        if result != kIOReturnSuccess {
            print("Error IOServiceGetMatchingServices(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
        
        device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        if device == 0 {
            print("Error IOIteratorNext(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
        
        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        if result != kIOReturnSuccess {
            print("Error IOServiceOpen(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
    }
    
    deinit {
        let result = self.close()
        if result != kIOReturnSuccess {
            print("error close smc connection: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
        }
    }
    
    public func close() -> kern_return_t {
        self.keyInfoLock.lock()
        defer { self.keyInfoLock.unlock() }
        self.keyInfoCache.removeAll()
        return IOServiceClose(conn)
    }
    
    public func getValue(_ key: String) -> Double? {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)
        
        result = read(&val)
        if result == kIOReturnNotFound { return nil }
        if result != kIOReturnSuccess {
            print("Error read(\(key)): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return nil
        }
        
        if val.dataSize > 0 {
            switch val.dataType {
            case SMCDataType.UI8.rawValue:
                return Double(val.bytes[0])
            case SMCDataType.UI16.rawValue:
                return Double(UInt16(bytes: (val.bytes[0], val.bytes[1])))
            case SMCDataType.UI32.rawValue:
                return Double(UInt32(bytes: (val.bytes[0], val.bytes[1], val.bytes[2], val.bytes[3])))
            case SMCDataType.SP1E.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 16384)
            case SMCDataType.SP3C.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 4096)
            case SMCDataType.SP4B.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 2048)
            case SMCDataType.SP5A.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 1024)
            case SMCDataType.SP69.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 512)
            case SMCDataType.SP78.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 256)
            case SMCDataType.SP87.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 128)
            case SMCDataType.SP96.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 64)
            case SMCDataType.SPA5.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 32)
            case SMCDataType.SPB4.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 16)
            case SMCDataType.SPF0.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return intValue
            case SMCDataType.FLT.rawValue:
                let value: Float? = Float(val.bytes)
                if value != nil {
                    return Double(value!)
                }
                return nil
            case SMCDataType.FPE2.rawValue:
                return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
            default:
                return nil
            }
        }
        
        return nil
    }
    
    public func fanModeKey(_ id: Int) -> String {
        if _fanModeKeyIsLower == nil {
            var probe = SMCVal_t("F0md")
            _fanModeKeyIsLower = read(&probe) == kIOReturnSuccess && probe.dataSize > 0
        }
        return _fanModeKeyIsLower! ? "F\(id)md" : "F\(id)Md"
    }

    // MARK: - internal functions
    
    private func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        guard value.pointee.key.count == 4, value.pointee.key.utf8.count == 4 else { return kIOReturnBadArgument }
        self.keyInfoLock.lock()
        defer { self.keyInfoLock.unlock() }
        
        var result: kern_return_t = 0
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        
        input.key = FourCharCode(fromString: value.pointee.key)
        let keyInfo: SMCKeyData_t.keyInfo_t
        var cacheable = true
        if let cached = self.keyInfoCache[input.key] {
            keyInfo = cached
        } else {
            input.data8 = SMCKeys.readKeyInfo.rawValue
            result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
            if result != kIOReturnSuccess {
                return result
            }
            // SMC reports an unavailable key as 0x84 during sensor probing.
            if output.result == 0x84 { return kIOReturnNotFound }
            if output.result != 0 { return kIOReturnError }
            keyInfo = output.keyInfo
            cacheable = output.result == 0 && keyInfo.dataSize > 0 && keyInfo.dataSize <= value.pointee.bytes.count && keyInfo.dataType != 0
        }
        
        value.pointee.dataSize = UInt32(keyInfo.dataSize)
        value.pointee.dataType = keyInfo.dataType.toString()
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue
        
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result == kIOReturnSuccess && output.result == 0 && cacheable {
            self.keyInfoCache[input.key] = keyInfo
        } else {
            self.keyInfoCache.removeValue(forKey: input.key)
        }
        if result != kIOReturnSuccess {
            return result
        }
        if output.result == 0x84 { return kIOReturnNotFound }
        if output.result != 0 { return kIOReturnError }
        
        memcpy(&value.pointee.bytes, &output.bytes, min(Int(value.pointee.dataSize), value.pointee.bytes.count))
        
        return kIOReturnSuccess
    }
    
    private func write(_ value: SMCVal_t) -> kern_return_t {
        guard value.key.count == 4, value.key.utf8.count == 4 else { return kIOReturnBadArgument }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        
        input.key = FourCharCode(fromString: value.key)
        input.data8 = SMCKeys.writeBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(value.dataSize)
        input.bytes = (value.bytes[0], value.bytes[1], value.bytes[2], value.bytes[3], value.bytes[4], value.bytes[5],
                       value.bytes[6], value.bytes[7], value.bytes[8], value.bytes[9], value.bytes[10], value.bytes[11],
                       value.bytes[12], value.bytes[13], value.bytes[14], value.bytes[15], value.bytes[16], value.bytes[17],
                       value.bytes[18], value.bytes[19], value.bytes[20], value.bytes[21], value.bytes[22], value.bytes[23],
                       value.bytes[24], value.bytes[25], value.bytes[26], value.bytes[27], value.bytes[28], value.bytes[29],
                       value.bytes[30], value.bytes[31])
        
        let result = self.call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        
        // IOKit can return kIOReturnSuccess but SMC firmware may still reject the write.
        // Check SMC-level result code (0x00 = success, non-zero = error)
        if output.result != 0x00 {
            return kIOReturnError
        }
        
        return kIOReturnSuccess
    }
    
    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}

// Basic Fan's deliberately narrow M1 path: no diagnostic unlocks.
extension SMC {
    private func basicWrite(_ key: String, value: Double) throws {
        var v = SMCVal_t(key)
        guard read(&v) == kIOReturnSuccess else { throw FanFailure(message: "Cannot read \(key).") }
        if v.dataType == "flt " && v.dataSize == 4 {
            let bytes = Float(value).bytes
            v.bytes.replaceSubrange(0..<4, with: bytes)
        } else if v.dataType == "ui8 " && v.dataSize == 1 && value >= 0 && value <= 255 {
            v.bytes[0] = UInt8(value)
        } else { throw FanFailure(message: "Unexpected format for \(key).") }
        var result = kIOReturnError
        for _ in 0..<3 {
            result = write(v)
            if result == kIOReturnSuccess { break }
            usleep(30_000)
        }
        guard result == kIOReturnSuccess else { throw FanFailure(message: "macOS rejected the fan setting (\(key)).") }
    }
    func basicManual(_ fan: FanInfo, percent: Double) throws {
        try basicManualRPM(fan, rpm: fan.target(percent))
    }
    func basicManualRPM(_ fan: FanInfo, rpm: Double) throws {
        guard rpm.isFinite, rpm >= fan.minimum, rpm <= fan.maximum else {
            throw FanFailure(message: "Requested RPM is outside this fan's supported range.")
        }
        let target = rpm.rounded()
        try verifyFanSetting(fanID: fan.id, target: target, apply: {
            if self.getValue(fan.modeKey) != 1 { try self.basicWrite(fan.modeKey, value: 1) }
            try self.basicWrite("F\(fan.id)Tg", value: target)
        }, read: {
            FanReadback(mode: self.getValue(fan.modeKey), target: self.getValue("F\(fan.id)Tg"))
        }, pause: { usleep(100_000) })
    }
    func basicAutomatic(_ fan: FanInfo) throws {
        // Automatic mode can also take a moment to become visible.
        for _ in 0..<6 {
            try basicWrite(fan.modeKey, value: 0)
            try basicWrite("F\(fan.id)Tg", value: 0)
            usleep(50_000)
            if let mode = getValue(fan.modeKey), mode == 0 || mode == 3 { return }
        }
        throw FanFailure(message: "Automatic mode could not be verified for fan \(fan.id + 1).")
    }
}

//
//  DeviceInfo.swift
//  Cool Uncle
//
//  Device information utilities for bug reporting
//

import Foundation
import UIKit

struct DeviceInfo {

    /// Get the specific device model (e.g., "iPhone 12", "iPhone 15 Pro")
    static func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else {
                return identifier
            }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }

        return mapToDeviceModel(identifier: identifier)
    }

    /// Map hardware identifier to human-readable device name
    private static func mapToDeviceModel(identifier: String) -> String {
        switch identifier {
        // iPhone
        case "iPhone8,1":                               return "iPhone 6s"
        case "iPhone8,2":                               return "iPhone 6s Plus"
        case "iPhone8,4":                               return "iPhone SE (1st gen)"
        case "iPhone9,1", "iPhone9,3":                  return "iPhone 7"
        case "iPhone9,2", "iPhone9,4":                  return "iPhone 7 Plus"
        case "iPhone10,1", "iPhone10,4":                return "iPhone 8"
        case "iPhone10,2", "iPhone10,5":                return "iPhone 8 Plus"
        case "iPhone10,3", "iPhone10,6":                return "iPhone X"
        case "iPhone11,2":                              return "iPhone XS"
        case "iPhone11,4", "iPhone11,6":                return "iPhone XS Max"
        case "iPhone11,8":                              return "iPhone XR"
        case "iPhone12,1":                              return "iPhone 11"
        case "iPhone12,3":                              return "iPhone 11 Pro"
        case "iPhone12,5":                              return "iPhone 11 Pro Max"
        case "iPhone12,8":                              return "iPhone SE (2nd gen)"
        case "iPhone13,1":                              return "iPhone 12 mini"
        case "iPhone13,2":                              return "iPhone 12"
        case "iPhone13,3":                              return "iPhone 12 Pro"
        case "iPhone13,4":                              return "iPhone 12 Pro Max"
        case "iPhone14,2":                              return "iPhone 13 Pro"
        case "iPhone14,3":                              return "iPhone 13 Pro Max"
        case "iPhone14,4":                              return "iPhone 13 mini"
        case "iPhone14,5":                              return "iPhone 13"
        case "iPhone14,6":                              return "iPhone SE (3rd gen)"
        case "iPhone14,7":                              return "iPhone 14"
        case "iPhone14,8":                              return "iPhone 14 Plus"
        case "iPhone15,2":                              return "iPhone 14 Pro"
        case "iPhone15,3":                              return "iPhone 14 Pro Max"
        case "iPhone15,4":                              return "iPhone 15"
        case "iPhone15,5":                              return "iPhone 15 Plus"
        case "iPhone16,1":                              return "iPhone 15 Pro"
        case "iPhone16,2":                              return "iPhone 15 Pro Max"
        case "iPhone17,1":                              return "iPhone 16 Pro"
        case "iPhone17,2":                              return "iPhone 16 Pro Max"
        case "iPhone17,3":                              return "iPhone 16"
        case "iPhone17,4":                              return "iPhone 16 Plus"
        case "iPhone17,5":                              return "iPhone 16e"
        case "iPhone18,1":                              return "iPhone 17 Pro"
        case "iPhone18,2":                              return "iPhone 17 Pro Max"
        case "iPhone18,3":                              return "iPhone 17"
        case "iPhone18,4":                              return "iPhone 17 Air"

        // iPad
        case "iPad6,11", "iPad6,12":                    return "iPad (5th gen)"
        case "iPad7,5", "iPad7,6":                      return "iPad (6th gen)"
        case "iPad7,11", "iPad7,12":                    return "iPad (7th gen)"
        case "iPad11,6", "iPad11,7":                    return "iPad (8th gen)"
        case "iPad12,1", "iPad12,2":                    return "iPad (9th gen)"
        case "iPad13,18", "iPad13,19":                  return "iPad (10th gen)"
        case "iPad6,3", "iPad6,4":                      return "iPad Pro 9.7-inch"
        case "iPad7,3", "iPad7,4":                      return "iPad Pro 10.5-inch"
        case "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4": return "iPad Pro 11-inch (1st gen)"
        case "iPad8,9", "iPad8,10":                     return "iPad Pro 11-inch (2nd gen)"
        case "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7": return "iPad Pro 11-inch (3rd gen)"
        case "iPad14,3", "iPad14,4":                    return "iPad Pro 11-inch (4th gen)"
        case "iPad6,7", "iPad6,8":                      return "iPad Pro 12.9-inch (1st gen)"
        case "iPad7,1", "iPad7,2":                      return "iPad Pro 12.9-inch (2nd gen)"
        case "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8": return "iPad Pro 12.9-inch (3rd gen)"
        case "iPad8,11", "iPad8,12":                    return "iPad Pro 12.9-inch (4th gen)"
        case "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11": return "iPad Pro 12.9-inch (5th gen)"
        case "iPad14,5", "iPad14,6":                    return "iPad Pro 12.9-inch (6th gen)"
        case "iPad11,1", "iPad11,2":                    return "iPad mini (5th gen)"
        case "iPad14,1", "iPad14,2":                    return "iPad mini (6th gen)"
        case "iPad5,1", "iPad5,2":                      return "iPad mini 4"
        case "iPad11,3", "iPad11,4":                    return "iPad Air (3rd gen)"
        case "iPad13,1", "iPad13,2":                    return "iPad Air (4th gen)"
        case "iPad13,16", "iPad13,17":                  return "iPad Air (5th gen)"
        case "iPad14,8", "iPad14,9":                    return "iPad Air 11-inch (6th gen)"
        case "iPad14,10", "iPad14,11":                  return "iPad Air 13-inch (6th gen)"

        // Simulator
        case "i386", "x86_64", "arm64":
            let modelName = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iOS Simulator"
            if modelName != "iOS Simulator" {
                return mapToDeviceModel(identifier: modelName) + " (Simulator)"
            }
            return "iOS Simulator"

        default:
            return identifier // Return raw identifier if unknown
        }
    }

    /// Get complete device information for bug reports
    static func getBugReportDeviceInfo() -> (model: String, identifier: String) {
        var systemInfo = utsname()
        uname(&systemInfo)

        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else {
                return identifier
            }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }

        let model = mapToDeviceModel(identifier: identifier)
        return (model: model, identifier: identifier)
    }
}

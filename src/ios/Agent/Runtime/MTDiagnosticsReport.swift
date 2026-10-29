//
//  MTDiagnosticsReport.swift
//  Minis — MT 风格的运行诊断报告生成器
//
//  参照 MT-Agent 1.1.0 的诊断输出格式，生成纯文本诊断报告。
//  格式：【分组标题】+ key + status + detail
//

import Foundation
import UIKit

/// MT 风格的诊断报告结构
struct MTDiagnosticsReport {
    let timestamp: Date
    let elapsed: TimeInterval
    let device: String
    let iosVersion: String
    let appVersion: String
    let appBuild: String
    let conclusion: String
    
    var sections: [Section]
    
    struct Section {
        let title: String
        var items: [Item]
    }
    
    struct Item {
        let key: String
        let status: Status
        let detail: String?
        
        enum Status: String {
            case ok = "✓"
            case warning = "⚠"
            case failed = "✗"
            case skipped = "○"
            case running = "⋯"
        }
    }
    
    /// 生成 MT 风格的纯文本报告
    func formatted() -> String {
        var lines: [String] = []
        
        // 标题块
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        let timeStr = formatter.string(from: timestamp)
        let elapsedStr = String(format: "%.1f", elapsed)
        
        lines.append("Minis 运行诊断")
        lines.append("时间：\(timeStr)（用时 \(elapsedStr) 秒）")
        lines.append("设备：\(device) · iOS \(iosVersion)")
        lines.append("App：\(appVersion) (\(appBuild))")
        lines.append("结论：\(conclusion)")
        lines.append("")
        
        // 各个分组
        for section in sections {
            lines.append("【\(section.title)】")
            for item in section.items {
                let paddedKey = item.key.padding(toLength: 20, withPad: " ", startingAt: 0)
                let statusStr = item.status.rawValue
                if let detail = item.detail, !detail.isEmpty {
                    lines.append("\(paddedKey) \(statusStr)  \(detail)")
                } else {
                    lines.append("\(paddedKey) \(statusStr)")
                }
            }
            lines.append("")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// 从诊断视图的状态构建报告
    static func build(from model: RuntimeDiagnosticsModel, 
                      elapsed: TimeInterval,
                      finishedAt: Date) -> MTDiagnosticsReport {
        let device = UIDevice.current.modelIdentifier
        let iosVersion = UIDevice.current.systemVersion
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        
        // 判断总体结论
        let allItems = model.basic + model.project + model.optional + model.execution + model.runtimes
        let hasFailures = allItems.contains { if case .failed = $0.status { return true }; return false }
        let hasWarnings = allItems.contains { if case .skipped = $0.status { return true }; return false }
        let conclusion = hasFailures ? "存在问题" : (hasWarnings ? "部分功能不可用" : "核心能力正常")
        
        var sections: [Section] = []
        
        // 基础运行
        sections.append(Section(
            title: "Runtime Compatibility Probe",
            items: convertItems(model.basic)
        ))
        
        // 项目能力
        sections.append(Section(
            title: "项目能力",
            items: convertItems(model.project)
        ))
        
        // 可选能力
        sections.append(Section(
            title: "可选能力",
            items: convertItems(model.optional)
        ))
        
        // 执行层（MT 1.1.0 新增）
        if !model.execution.isEmpty {
            sections.append(Section(
                title: "执行层",
                items: convertItems(model.execution)
            ))
        }
        
        // 已安装运行时
        if !model.runtimes.isEmpty {
            sections.append(Section(
                title: "已安装运行时",
                items: convertItems(model.runtimes)
            ))
        }
        
        return MTDiagnosticsReport(
            timestamp: finishedAt,
            elapsed: elapsed,
            device: device,
            iosVersion: iosVersion,
            appVersion: appVersion,
            appBuild: appBuild,
            conclusion: conclusion,
            sections: sections
        )
    }
    
    private static func convertItems(_ items: [RuntimeDiagItem]) -> [Item] {
        items.map { item in
            let status: Item.Status
            let detail: String?
            
            switch item.status {
            case .pending:
                status = .skipped
                detail = nil
            case .running:
                status = .running
                detail = nil
            case .ok:
                status = .ok
                detail = item.detail.isEmpty ? nil : item.detail
            case .failed(let reason):
                status = .failed
                detail = reason + (item.detail.isEmpty ? "" : " · \(item.detail)")
            case .skipped(let reason):
                status = .skipped
                detail = reason + (item.detail.isEmpty ? "" : " · \(item.detail)")
            }
            
            return Item(key: item.title, status: status, detail: detail)
        }
    }
}

// MARK: - UIDevice 扩展

extension UIDevice {
    /// 获取设备型号标识符（例如 iPhone14,2）
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}

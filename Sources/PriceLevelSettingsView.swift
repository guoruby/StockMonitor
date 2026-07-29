import SwiftUI

struct PriceLevelSettingsView: View {
    @ObservedObject private var store = PriceLevelStore.shared
    @ObservedObject private var monitorState = MonitorState.shared

    @State private var hs300Support: String = ""
    @State private var hs300Pressure: String = ""
    @State private var stockSupport: String = ""
    @State private var stockPressure: String = ""
    @State private var stockCodeInput: String = ""

    var body: some View {
        VStack(spacing: 16) {
            // 沪深300
            VStack(alignment: .leading, spacing: 8) {
                Text("沪深300 大盘")
                    .font(.headline)
                if let level = store.hs300Level {
                    Text("当前：支撑 \(String(format: "%.2f", level.support))  压力 \(String(format: "%.2f", level.pressure))  生效 \(level.validDate)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("未设置")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("支撑位").font(.caption)
                        TextField("支撑", text: $hs300Support)
                            .frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("压力位").font(.caption)
                        TextField("压力", text: $hs300Pressure)
                            .frame(width: 100)
                    }
                    Button("保存") {
                        if let s = Double(hs300Support), let p = Double(hs300Pressure), s > 0, p > 0 {
                            store.setHS300Level(support: s, pressure: p)
                            hs300Support = ""
                            hs300Pressure = ""
                        }
                    }
                    Button("清除") {
                        store.hs300Level = nil
                        store.save()
                    }
                }
            }

            Divider()

            // 个股
            VStack(alignment: .leading, spacing: 8) {
                Text("个股")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("代码：")
                    TextField("如 600000", text: $stockCodeInput)
                        .frame(width: 100)
                    Button("加载已有") {
                        loadStockLevel()
                    }
                    if let code = monitorState.stockCode as String?, !code.isEmpty {
                        Button("用当前监控股") {
                            stockCodeInput = code
                            loadStockLevel()
                        }
                    }
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("支撑位").font(.caption)
                        TextField("支撑", text: $stockSupport)
                            .frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("压力位").font(.caption)
                        TextField("压力", text: $stockPressure)
                            .frame(width: 100)
                    }
                    Button("保存") {
                        let code = stockCodeInput.isEmpty ? monitorState.stockCode : stockCodeInput
                        if let s = Double(stockSupport), let p = Double(stockPressure), !code.isEmpty, s > 0, p > 0 {
                            store.setStockLevel(code: code, support: s, pressure: p)
                            stockSupport = ""
                            stockPressure = ""
                        }
                    }
                    Button("清除") {
                        if !stockCodeInput.isEmpty {
                            store.stockLevels.removeValue(forKey: stockCodeInput)
                            store.save()
                        }
                    }
                }
                // 显示已设置个股列表
                if !store.stockLevels.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(store.stockLevels.keys.sorted()), id: \.self) { code in
                                if let level = store.stockLevels[code] {
                                    HStack {
                                        Text("\(code)")
                                        Text("支撑 \(String(format: "%.2f", level.support))")
                                        Text("压力 \(String(format: "%.2f", level.pressure))")
                                        Text("生效 \(level.validDate)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .font(.caption)
                                    .onTapGesture {
                                        stockCodeInput = code
                                        stockSupport = String(level.support)
                                        stockPressure = String(level.pressure)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }

            Spacer()

            // 规则说明
            VStack(alignment: .leading, spacing: 2) {
                Text("规则说明：")
                    .font(.caption.bold())
                Text("• 收盘后(>15:00)设置 → 下一交易日生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• 盘前/盘中设置 → 当天生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• 突破压力位 → 买入信号维度；跌破支撑位 → 卖出信号维度")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• 多个因子叠加才触发最终买卖信号")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420, height: 480)
    }

    private func loadStockLevel() {
        if let level = store.getStockLevel(code: stockCodeInput) {
            stockSupport = String(level.support)
            stockPressure = String(level.pressure)
        }
    }
}

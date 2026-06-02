#!/usr/bin/env python3
import sys
sys.path.insert(0, '.')

from stock_monitor_api import get_realtime_data, vision_ocr, parse_ocr_results

print("=" * 60)
print("1. 测试 API 数据获取 (603687 大胜达)...")
data = get_realtime_data("603687")
if data:
    print(f"  名称: {data['name']}")
    print(f"  最新价: {data['price']}")
    print(f"  VWAP: {data['vwap']:.4f}")
    print(f"  偏离: {data['deviation']:.2f}%")
    print(f"  涨跌幅: {data['change_pct']:.2f}%")
    print(f"  量比: {data['vol_ratio']} | 主力: {data.get('flow_strength',0):+.1f}%")
else:
    print("  失败 (非交易时段)")

print("\n" + "=" * 60)
print("2. 测试 Vision OCR (股票名+均价+最新价区域)...")
try:
    region = {"top": 95, "left": 275, "width": 180, "height": 55}
    results = vision_ocr(region)
    
    if results:
        print(f"  识别到 {len(results)} 条原始结果:")
        for r in results:
            print(f'    "{r["text"]}" ({r["confidence"]*100:.0f}%)')
        
        parsed = parse_ocr_results(results)
        print()
        print("  解析结果:")
        print(f"    股票名:   {parsed['name'] or '(未识别)'}")
        print(f"    股票代码: {parsed['code'] or '(未识别)'}")
        print(f"    均价:     {parsed['avg_price'] or '(未识别)'}")
        print(f"    最新价:   {parsed['current_price'] or '(未识别)'}")
        
        if data and parsed["current_price"]:
            ocr_price = parsed["current_price"]
            api_price = data["price"]
            diff = abs(ocr_price - api_price)
            print()
            if diff < 0.02:
                print(f"  ✅ OCR价格({ocr_price}) 与API({api_price}) 完全匹配!")
            else:
                print(f"  ⚠️ OCR价格({ocr_price}) vs API({api_price}) 差异{diff:.2f}")
    else:
        print("  ⚠️ 未识别到文字 (同花顺窗口可能不在该位置)")
except Exception as e:
    print(f"  ❌ 异常: {e}")
    import traceback
    traceback.print_exc()

print("\n" + "=" * 60)
print("3. 测试 Vision OCR (均价+最新价区域 - 小区域)...")
try:
    region2 = {"top": 587, "left": 342, "width": 208, "height": 15}
    results2 = vision_ocr(region2)
    
    if results2:
        print(f"  识别到 {len(results2)} 条:")
        for r in results2:
            print(f'    "{r["text"]}"')
        
        parsed2 = parse_ocr_results(results2)
        print(f"\n  解析: 均价={parsed2['avg_price']}, 最新={parsed2['current_price']}")
except Exception as e:
    print(f"  ❌ 异常: {e}")

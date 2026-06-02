"""
分时均价线（VWAP）检查模块 v3.1

直接从腾讯实时接口计算 VWAP，结合量价综合判断买卖点。
增强：外盘/内盘（主力资金流向）提高信号准确度

信号提升逻辑：
- 主力净买入（外盘 > 内盘）+ 价格在VWAP上方 = 买入信号加分
- 主力净卖出（内盘 > 外盘）+ 价格在VWAP下方 = 卖出信号加分
"""

import requests
import json
import os
from datetime import datetime, time
from typing import Dict, Optional, Tuple


def _is_trading_time() -> bool:
    """判断是否在交易时间（9:30-15:00，工作日）"""
    now = datetime.now()
    if now.weekday() >= 5:
        return False
    current_time = now.time()
    morning_start = time(9, 30)
    morning_end = time(11, 30)
    afternoon_start = time(13, 0)
    afternoon_end = time(15, 0)
    
    if (morning_start <= current_time <= morning_end or 
        afternoon_start <= current_time <= afternoon_end):
        return True
    return False


def _get_trading_period() -> str:
    """获取当前交易时段"""
    now = datetime.now()
    current_time = now.time()
    if time(9, 30) <= current_time <= time(10, 30):
        return "开盘初期"
    elif time(10, 30) <= current_time <= time(11, 30):
        return "早盘尾段"
    elif time(13, 0) <= current_time <= time(14, 30):
        return "午盘"
    elif time(14, 30) <= current_time <= time(15, 0):
        return "尾盘"
    return "非交易时段"


def get_realtime_data(stock_code: str, timeout: int = 5) -> Optional[Dict]:
    """从腾讯实时接口获取完整分时数据"""
    if stock_code.startswith('sh') or stock_code.startswith('sz'):
        tencent_code = stock_code
    elif stock_code.startswith('6'):
        tencent_code = f'sh{stock_code}'
    else:
        tencent_code = f'sz{stock_code}'
    
    url = f"https://qt.gtimg.cn/q={tencent_code}"
    
    try:
        r = requests.get(url, timeout=timeout)
        r.encoding = 'gbk'
        if r.status_code != 200:
            return None
        
        text = r.text.strip()
        if '~' not in text:
            return None
        
        parts = text.split('~')
        if len(parts) < 50:
            return None
        
        price = float(parts[3]) if parts[3] else 0
        if price == 0:
            return None
        
        # 基础数据
        open_price = float(parts[5]) if parts[5] else 0
        volume = int(parts[6]) * 100 if parts[6] else 0
        amount = float(parts[37]) * 10000 if parts[37] else 0
        change_pct = float(parts[32]) if parts[32] else 0
        high = float(parts[41]) if len(parts) > 41 and parts[41] else price
        low = float(parts[42]) if len(parts) > 42 and parts[42] else price
        
        # 主力资金数据（外盘=主动买盘，内盘=主动卖盘）
        # parts[7] = 外盘(手)，parts[8] = 内盘(手)
        buy_volume = int(parts[7]) * 100 if parts[7] else 0  # 主动性买入
        sell_volume = int(parts[8]) * 100 if parts[8] else 0  # 主动性卖出
        
        # 主力净流入 = 外盘 - 内盘
        net_flow = buy_volume - sell_volume
        # 主力资金强度：净流入占总成交的比例，>0表示主力净买入
        flow_strength = (net_flow / volume * 100) if volume > 0 else 0
        
        # 五档买卖盘数据（用于判断买卖压力）
        # 买盘1-5: parts[9,11,13,15,17] 价格, parts[10,12,14,16,18] 量
        # 卖盘1-5: parts[19,21,23,25,27] 价格, parts[20,22,24,26,28] 量
        buy_pressure = 0
        sell_pressure = 0
        for i in [10, 12, 14, 16, 18]:  # 买盘5档量
            if len(parts) > i and parts[i]:
                buy_pressure += int(parts[i])
        for i in [20, 22, 24, 26, 28]:  # 卖盘5档量
            if len(parts) > i and parts[i]:
                sell_pressure += int(parts[i])
        pressure_ratio = buy_pressure / sell_pressure if sell_pressure > 0 else 1.0
        
        vwap = amount / volume if volume > 0 else price
        
        # 真实量比（腾讯已计算）
        vol_ratio = float(parts[46]) if len(parts) > 46 and parts[46] else 1.0
        
        return {
            'price': price,
            'vwap': vwap,
            'volume': volume,
            'amount': amount,
            'change_pct': change_pct,
            'open': open_price,
            'high': high,
            'low': low,
            'vol_ratio': round(vol_ratio, 2),
            # 主力资金数据
            'buy_volume': buy_volume,
            'sell_volume': sell_volume,
            'net_flow': net_flow,
            'flow_strength': round(flow_strength, 2),
            # 买卖压力
            'buy_pressure': buy_pressure,
            'sell_pressure': sell_pressure,
            'pressure_ratio': round(pressure_ratio, 2),
        }
    except Exception as e:
        return None


def analyze_volume_price(stock_code: str, data: Dict) -> Dict:
    """量价综合分析 + 主力资金增强"""
    result = {
        'pattern': 'normal',
        'buy_signal': False,
        'sell_signal': False,
        'confidence': 50,
        'reason': '',
        'volume_status': 'normal',
        'money_signal': 0,  # 主力资金信号: +正向买入, -负向卖出
    }
    
    price = data['price']
    vwap = data['vwap']
    volume = data['volume']
    change_pct = data['change_pct']
    vol_ratio = data.get('vol_ratio', 1.0)
    
    # 主力资金数据
    flow_strength = data.get('flow_strength', 0)  # 主力净买入占比
    pressure_ratio = data.get('pressure_ratio', 1.0)  # 买卖盘压力比
    
    vwap_distance = (price - vwap) / vwap * 100 if vwap > 0 else 0
    price_above_vwap = price > vwap
    period = _get_trading_period()
    
    # 主力资金基准分数调整
    base_adjust = 0
    
    # 主力净买入 > 5% 且价格在VWAP上方
    if flow_strength > 5 and price_above_vwap:
        base_adjust += 10
        result['money_signal'] = 1
    # 主力净卖出 < -5% 且价格在VWAP下方
    elif flow_strength < -5 and not price_above_vwap:
        base_adjust -= 10
        result['money_signal'] = -1
    # 买卖盘压力比 > 1.2
    if pressure_ratio > 1.2:
        base_adjust += 5
    elif pressure_ratio < 0.8:
        base_adjust -= 5
    
    if vol_ratio > 1.5:
        result['volume_status'] = '放量'
    elif vol_ratio < 0.7:
        result['volume_status'] = '缩量'
    else:
        result['volume_status'] = '平量'
    
    # === 买入信号 ===
    if price_above_vwap and vwap_distance > 0.5 and vol_ratio > 1.2:
        result['pattern'] = '放量突破'
        result['buy_signal'] = True
        base_conf = min(95, 70 + vol_ratio * 10)
        result['confidence'] = min(100, base_conf + base_adjust)
        result['reason'] = f"放量突破均价线+{vwap_distance:.1f}%，量比{vol_ratio:.1f}"
    
    elif not price_above_vwap and vwap_distance > -1 and vol_ratio < 0.8:
        if abs(price - vwap) < price * 0.02:
            result['pattern'] = '缩量回踩'
            result['buy_signal'] = True
            base_conf = min(90, 65 + (1 - vol_ratio) * 30)
            result['confidence'] = min(100, base_conf + base_adjust)
            result['reason'] = f"缩量回踩均价线({vol_ratio:.1f}x)，主力控盘"
    
    elif period == "开盘初期" and change_pct > 0 and vol_ratio < 0.6:
        if data.get('low') > 0 and price > data['open'] * 1.005:
            result['pattern'] = '开盘缩量探底回升'
            result['buy_signal'] = True
            result['confidence'] = min(100, 80 + base_adjust)
            result['reason'] = "开盘缩量震荡后放量拉升，主力控盘明显"
    
    elif period == "尾盘" and change_pct > 2 and vol_ratio > 1.5:
        result['pattern'] = '尾盘放量'
        result['buy_signal'] = True
        result['confidence'] = min(100, 75 + base_adjust)
        result['reason'] = f"尾盘放量拉升({vol_ratio:.1f}x)，明日有惯性"
    
    # 主力净买入 + 放量突破 = 强强联合
    if result['buy_signal'] and flow_strength > 10 and vol_ratio > 1.5:
        result['confidence'] = min(100, result['confidence'] + 8)
        result['reason'] += f"，主力净买入{flow_strength:.1f}%"
    
    # === 卖出信号 ===
    if change_pct > 3 and vol_ratio < 0.6 and vwap_distance > 3:
        result['pattern'] = '量价背离'
        result['sell_signal'] = True
        base_conf = 85
        result['confidence'] = min(100, base_conf + abs(base_adjust))
        result['reason'] = f"缩量上涨({vol_ratio:.1f}x)远离均价{vwap_distance:.1f}%，背离信号"
    
    elif not price_above_vwap and vwap_distance < -2 and vol_ratio > 1.5:
        result['pattern'] = '放量破位'
        result['sell_signal'] = True
        base_conf = 80
        result['confidence'] = min(100, base_conf + abs(base_adjust))
        result['reason'] = f"放量跌破均价线，量比{vol_ratio:.1f}，下跌信号"
    
    elif change_pct > 7 and vol_ratio < 0.5:
        result['pattern'] = '高位滞涨'
        result['sell_signal'] = True
        result['confidence'] = min(100, 75 + abs(base_adjust))
        result['reason'] = f"涨幅{change_pct:.1f}%但量比仅{vol_ratio:.1f}，滞涨信号"
    
    # 主力净卖出 + 下跌 = 双重确认
    if result['sell_signal'] and flow_strength < -10:
        result['confidence'] = min(100, result['confidence'] + 8)
        result['reason'] += f"，主力净卖出{flow_strength:.1f}%"
    
    return result


def check_vwap_signal(stock_code: str) -> Dict:
    """量价综合判断买卖点（v3.1 增加主力资金增强）"""
    is_trading = _is_trading_time()
    
    result = {
        'price_above_vwap': False,
        'vwap': 0,
        'vwap_distance_pct': 0,
        'signal': 'neutral',
        'recommendation': 'hold',
        'price': 0,
        'change_pct': 0,
        'volume_ratio': 1.0,
        'volume_status': 'normal',
        'pattern': 'normal',
        'pattern_reason': '',
        'pattern_confidence': 50,
        'buy_signal': False,
        'sell_signal': False,
        'period': _get_trading_period() if is_trading else '非交易时段',
        'is_trading': is_trading,
    }
    
    if not is_trading:
        result['skipped'] = True
        result['skip_reason'] = '非交易时间'
        return result
    
    data = get_realtime_data(stock_code)
    if not data:
        result['skipped'] = True
        result['skip_reason'] = '获取实时数据失败'
        return result
    
    price = data['price']
    vwap = data['vwap']
    change_pct = data['change_pct']
    vol_ratio = data.get('vol_ratio', 1.0)
    
    vwap_distance_pct = (price - vwap) / vwap * 100 if vwap > 0 else 0
    price_above_vwap = price > vwap
    period = _get_trading_period()
    
    vol_result = analyze_volume_price(stock_code, data)
    
    if price_above_vwap and vwap_distance_pct > 1:
        base_signal = 'strong'
    elif not price_above_vwap and vwap_distance_pct < -1:
        base_signal = 'weak'
    else:
        base_signal = 'neutral'
    
    # 买入信号判断
    if vol_result['sell_signal']:
        final_signal = 'sell' if vol_result['pattern'] in ['高位滞涨', '放量破位'] else 'weak'
        final_recommendation = 'sell' if final_signal == 'sell' else 'hold'
    elif vol_result['buy_signal'] and vol_result['confidence'] >= 70:
        final_signal = 'strong'
        final_recommendation = 'buy'
    elif base_signal == 'strong':
        final_signal = 'strong'
        final_recommendation = 'buy'
    elif base_signal == 'weak':
        final_signal = 'weak'
        final_recommendation = 'avoid'
    else:
        final_signal = 'neutral'
        final_recommendation = 'hold'
    
    result.update({
        'price_above_vwap': price_above_vwap,
        'vwap': round(vwap, 2),
        'vwap_distance_pct': round(vwap_distance_pct, 2),
        'signal': final_signal,
        'recommendation': final_recommendation,
        'price': price,
        'change_pct': change_pct,
        'volume_ratio': vol_ratio,
        'volume_status': vol_result['volume_status'],
        'pattern': vol_result['pattern'],
        'pattern_reason': vol_result['reason'],
        'pattern_confidence': vol_result['confidence'],
        'buy_signal': vol_result['buy_signal'],
        'sell_signal': vol_result['sell_signal'],
        'period': period,
        'volume': data['volume'],
        'amount': data['amount'],
        # 主力资金数据（内部使用，不对外展示）
        '_flow_strength': data.get('flow_strength', 0),
        '_pressure_ratio': data.get('pressure_ratio', 1.0),
        '_money_signal': vol_result.get('money_signal', 0),
    })
    
    return result


if __name__ == "__main__":
    import sys
    codes = sys.argv[1:] if len(sys.argv) > 1 else ['000001', '600000']
    
    for code in codes:
        print(f"\n{'='*50}")
        print(f"VWAP量价分析: {code}")
        result = check_vwap_signal(code)
        print(f"  时段: {result['period']}")
        print(f"  价格: ¥{result['price']} ({result['change_pct']:+.2f}%)")
        print(f"  VWAP: ¥{result['vwap']} ({result['vwap_distance_pct']:+.2f}%)")
        print(f"  量比: {result['volume_ratio']} ({result['volume_status']})")
        print(f"  形态: {result['pattern']}")
        print(f"  信号: {result['signal']} → {result['recommendation']}")
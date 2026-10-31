"""Receipt-based health history; no interpolation of outages or cross-epoch sums."""
import csv
from pathlib import Path

from .protocol import encode_status


def report_lines(session):
    rows = session.statuses
    lines = ['', '## 健康接收历史 ST', '',
             f'已知ST接收：{session.status_packets}；已提交：{len(rows)}；已知保存失败：{session.status_failures}。',
             '每条为实际收到的解码快照；无ST区间不能推断健康。主机单调时间用于接收间隔，UTC仅作标签。',
             '旧ST未携带EHealth，不能补造PHY状态；旧health缺字段经兼容解析可能为0，不据此认定健康。']
    if not rows:
        return lines + ['本存档没有健康历史（旧版存档或未收到ST）。']
    gaps = [(b.elapsed_ns-a.elapsed_ns)/1e9 for a, b in zip(rows, rows[1:])]
    lines += [f'最大已记录接收间隔：{max(gaps, default=0):.3f}秒；超过3秒的间隔：{sum(g > 3 for g in gaps)}次。',
              '区间首尾之前/之后及进程关闭后的停更不在上述间隔统计中；不是断网持续时长或设备可用率。',
              '', '| 连续身份段 | 首/末ST序号 | 设备/启动/考试 | 样本数 | 非fresh样本 cap/UI/eth | PHY异常或未知样本 | 末次fresh UDP发送/丢弃 |',
              '|---:|---|---|---:|---|---:|---|']
    # Split by contiguous identity, including unknown samples. Never merge
    # repeated identity after a restart, nor subtract asynchronously reset counters.
    groups = []
    for row in rows:
        h = row.packet.evidence_health
        key = h.identity if h else None
        if not groups or groups[-1][0] != key:
            groups.append((key, []))
        groups[-1][1].append(row)
    for number, (key, samples) in enumerate(groups, 1):
        unknown = [0, 0, 0]
        phy_bad = 0
        last_udp = None
        for row in samples:
            h = row.packet.evidence_health
            for domain in range(3):
                unknown[domain] += int(h is None or not h.domain_fresh(domain))
            if h is None or h.words[0] >> 24 != 2:
                phy_bad += 1
            else:
                p = h.words[31]
                # Valid, known, not stale, ID matched, TX delay, full duplex,
                # link, gigabit. RX delay intentionally not required by TX path.
                phy_bad += int((p & 0x3DF) != 0x2DE)
            if h and h.domain_fresh(2):
                last_udp = h.words[29:31]
        who = '/'.join(map(str, key)) if key else '未上报EHealth'
        udp = '/'.join(map(str, last_udp)) if last_udp is not None else '未知'
        lines.append(f'| {number} | {samples[0].receipt_id}/{samples[-1].receipt_id} | {who} | {len(samples)} | {"/".join(map(str, unknown))} | {phy_bad} | {udp} |')
    lines += ['', '计数为收到的样本数，不是唯一故障次数；UDP末次fresh读数属于该段末次可用快照，不跨段相加。']
    return lines


def export_status_csv(path, session):
    path = Path(path)
    if path.resolve() == Path(session.session_path).resolve():
        raise ValueError('Health CSV cannot overwrite capture database')
    with path.open('w', encoding='utf-8', newline='') as output:
        writer = csv.writer(output)
        writer.writerow(['host_session_id', 'receipt_id', 'received_at_utc', 'elapsed_ns', 'canonical_st'])
        for row in session.statuses:
            writer.writerow([session.host_session_id, row.receipt_id, row.received_at, row.elapsed_ns,
                             encode_status(row.packet).decode('ascii').strip()])

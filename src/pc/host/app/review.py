"""Read persisted evidence and export an explicitly scoped monitoring report."""

import json
from pathlib import Path
from datetime import datetime, timezone

from .exam_events import format_event, format_health, stage_name, risk_name
from .evidence_v2_store import read_revision
from .transaction_protocol import TransactionEventPacket
from .transaction_protocol import decode_transaction_event
from .history_association import read_history_record, verdict_for, PixelRecord

HISTORY_LABELS = {
    'complete': '联合完整', 'partial': '像素缺片', 'degraded': '历史降级',
    'failed': '取证失败', 'awaiting_result': '等待HR结果',
    'awaiting_pixels': '仅HR/等待像素', 'invalid': '证据校验失败',
}


def evidence_state(window):
    verdict = window.get('history_verdict')
    return (f"{HISTORY_LABELS.get(verdict, verdict)} ({verdict})" if verdict
            else window.get('status', '完整' if window['complete'] else '不完整'))


def history_details(window):
    """Verified HR fields, never infer unobserved gaps from missing UDP pixels."""
    parts = []
    for record in window.get('history', ()):
        text = (f"HR w{record.window}/t{record.token} code={record.code} 帧={record.frames} "
                f"窗口[{record.lower_ms},{record.upper_ms}]ms "
                f"gap={record.gap_count} unknown={int(record.gap_unknown)} "
                f"truncated={int(record.truncated)} coverage={int(record.coverage_ok)}")
        if record.gap_count:
            text += (f" 首末缺口={record.gap_first_time_ms}/{record.gap_last_time_ms}ms"
                     f" 原因=0x{record.gap_first_reason:02X}/0x{record.gap_last_reason:02X}")
        parts.append(text)
    if window.get('missing_indices'):
        parts.append('缺失/不完整帧索引=' + ','.join(map(str, window['missing_indices'])))
    if window.get('history_error'):
        parts.append('HR读取异常：' + window['history_error'])
    return '；'.join(parts) or '未收到HR；像素完整不代表历史窗口成功'


def load_evidence_review(root, *, event=None, identity=None, cancelled=None):
    """Strict latest EG + verified HR view, including result-only transactions.

    A bad latest revision is never replaced with an older complete one. Invalid
    HR invalidates its named transaction only; unreadable identities are shown
    as global errors rather than being assigned to an unrelated event.
    """
    directories = None
    if isinstance(event, TransactionEventPacket):
        from .evidence_v2_store import identity_name
        directories = [Path(root)/identity_name(event.identity)]
    elif event is not None and identity is not None:
        directories = list(Path(root).glob(
            f'egv2_{identity.device_id:08X}_{identity.boot_id:08X}_{identity.session_id:08X}_*'))
    windows, errors = load_windows(root, directories=directories,
                                   legacy=not isinstance(event,TransactionEventPacket), cancelled=cancelled,
                                   alarm=event if not isinstance(event,TransactionEventPacket) else None,
                                   identity=identity)
    history, bad = {}, {}
    history_root = Path(root)/'history_results'
    if isinstance(event,TransactionEventPacket):
        # Context directory is the full transaction. Also include conflicting
        # same-identity contexts so they remain a refusal, never a false bind.
        prefix=event.transaction[:20].hex()
        contexts=[p for p in history_root.glob('*') if p.name.lower().startswith(prefix)]
        history_paths=(p for context in contexts for p in context.rglob('manifest.json'))
    elif event is not None and identity is not None:
        # AL has no full ET identity. Only read HR for the verified pixel
        # candidates: an unrelated same-session HR must not appear as a false
        # "invalid/missing pixels" row simply because this is a targeted view.
        selected_contexts={w['transaction'].hex() for w in windows if w.get('protocol')=='EGv2'}
        contexts=[p for p in history_root.glob('*') if p.name.lower() in selected_contexts]
        history_paths=(p for context in contexts for p in context.rglob('manifest.json'))
    else:
        history_paths=history_root.rglob('manifest.json')
    for path in sorted(history_paths):
        if cancelled and cancelled.is_set():
            return [], []
        context = path.parent.parent.name.upper()
        try:
            record = read_history_record(path)
            event = decode_transaction_event(record.transaction_hex)
            if context != event.transaction.hex().upper():
                raise ValueError('HR directory/transaction mismatch')
            history.setdefault(context, []).append(record)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            errors.append(f'{path}: {exc}')
            bad[context] = str(exc)
    by_context = {}
    for w in windows:
        if w.get('protocol') != 'EGv2':
            continue
        context = w['transaction'].hex().upper()
        by_context[context] = w
        records = history.get(context, ())
        pixel = PixelRecord(w['path']/'manifest.json', context, w['status'], w['complete'],
                            len(w['frames']), w['expected'], tuple(w['missing_indices'] or ()),
                            w['stream_bad'], w['identity'])
        verdict = verdict_for(context, records, [pixel])
        w.update(history=tuple(records), history_verdict=verdict.verdict)
        if records and w['expected'] is not None and any(r.frames != w['expected'] for r in records):
            w.update(history_verdict='invalid', history_error='HR帧数与EG结果不一致')
        if context in bad:
            w.update(history_verdict='invalid', history_error=bad[context])
    for context, records in history.items():
        if context in by_context:
            continue
        event = decode_transaction_event(context)
        # If a same-identity latest EG failed validation, never present an older
        # revision as a replacement. The visible row remains result-only.
        w = dict(path=records[0].manifest_path.parent.resolve(), frames=[], expected=records[0].frames,
                 complete=False, protocol='HR', status='awaiting_pixels', identity=event.identity,
                 transaction=event.transaction, source_time_ms=event.timestamp,
                 history=tuple(records), history_verdict='awaiting_pixels', missing_indices=[], stream_bad=False)
        w['history_verdict'] = verdict_for(context, records, []).verdict
        directory = Path(root)/('egv2_'+'_'.join(f'{v:0{16 if i == 3 else 8}X}' for i,v in enumerate(event.identity)))
        if list(directory.glob('revision_*/manifest.json')):
            w.update(history_verdict='invalid', history_error='同身份最新EG归档校验失败；不回退旧版本')
        if context in bad:
            w.update(history_verdict='invalid', history_error=bad[context])
        windows.append(w)
    for context, error in bad.items():
        if context in by_context or context in history:
            continue
        try:
            event = decode_transaction_event(context)
        except ValueError:
            continue  # cannot assign untrusted bytes to an event; error stays global
        windows.append(dict(path=(Path(root)/'history_results'/context.lower()).resolve(), frames=[], expected=None,
                            complete=False, protocol='HR', status='invalid', identity=event.identity,
                            transaction=event.transaction, source_time_ms=event.timestamp,
                            history=(), history_verdict='invalid', history_error=error,
                            missing_indices=[], stream_bad=False))
    return windows, errors


def load_windows(root, *, directories=None, legacy=True, cancelled=None, alarm=None, identity=None):
    windows, errors = [], []
    for manifest in sorted(Path(root).glob("event_*/manifest.json")) if legacy else ():
        if cancelled and cancelled.is_set():
            return [], []
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            frames = sorted(data["frames"], key=lambda f: int(f["index"]))
            expected = int(data["expected_frames"])
            if expected <= 0:
                raise ValueError("expected_frames must be positive")
            indices = [int(f["index"]) for f in frames]
            if len(set(indices)) != len(indices) or any(i < 0 or i >= expected for i in indices):
                raise ValueError("invalid frame indices")
            directory = manifest.parent.resolve()
            for frame in frames:
                image = (directory / frame["file"]).resolve()
                if image.parent != directory:
                    raise ValueError("image path outside window")
                int(frame["timestamp_ms"])
                int(frame["frame_id"])
            complete = (set(indices) == set(range(expected)) and
                        all((directory / f["file"]).is_file() for f in frames))
            windows.append(dict(path=directory, frames=frames, expected=expected,
                                complete=complete, seq=int(data["event_seq"])))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            errors.append(f"{manifest}: {exc}")
    for directory in sorted(Path(root).glob('egv2_*') if directories is None else directories):
        if cancelled and cancelled.is_set():
            return [], []
        manifests = sorted(directory.glob('revision_*/manifest.json'))
        if not manifests:
            continue
        manifest = manifests[-1]
        try:
            if alarm is not None and identity is not None:
                # Manifest is only an untrusted search index here. Do not
                # decode/rebuild unrelated multi-megabyte raw windows on an AL
                # click. Every candidate still goes through read_revision below
                # before it can be returned or displayed.
                header=json.loads(manifest.read_text(encoding='utf-8'))
                indexed=dict(protocol='EGv2',transaction=bytes.fromhex(header['transaction_hex']),
                             frames=header['frames'])
                if not legacy_transaction_candidates(alarm,identity,[indexed]):
                    continue
            data, assembly, _packets = read_revision(manifest.parent)
            windows.append(dict(path=manifest.parent.resolve(), frames=data['frames'], expected=data['expected_frames'],
                                complete=data['complete'], protocol='EGv2', status=data['status'],
                                 identity=assembly.identity, transaction=assembly.transaction,
                                 source_time_ms=data['source_time_ms'], missing_indices=data['missing_indices'],
                                 stream_bad=data['stream_bad']))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            errors.append(f'{manifest}: {exc}')
    return windows, errors


def legacy_transaction_candidates(packet, identity, windows):
    """AL/EI namespaces differ from ET. Offer bounded candidates, never bind UID.

    Require board+boot+session, code, and the actual captured frame/time span
    (with one sample of tolerance). AL panel time is not ET source time.
    Ambiguity stays visible. Pixel frames alone do not establish event identity.
    """
    if identity is None:
        return []
    result=[]
    for window in windows:
        if window.get('protocol') not in ('EGv2','HR'):
            continue
        transaction=window.get('transaction')
        if transaction is None:
            continue
        event=TransactionEventPacket(transaction)
        frames=window.get('frames',())
        times=[int(f['timestamp_ms']) for f in frames]
        ids=[int(f['frame_id']) for f in frames]
        in_span=(times and min(times)-100<=packet.timestamp<=max(times)+100 and
                 min(ids)-6<=packet.frame_id<=max(ids)+6)
        if (event.identity[:3] == (identity.device_id,identity.boot_id,identity.session_id)
                and event.event_code==packet.event_code and in_span):
            result.append(window)
    return result


def candidate_windows(packet, windows):
    """Conservative candidates only: time AND frame must fall in one window.

    Counter rollback/wrap inside a window is deliberately not matched. Even a
    unique result cannot establish session identity with the current protocol.
    """
    result = []
    for window in windows:
        if window.get('protocol') in ('EGv2', 'HR'):
            continue
        frames = window["frames"]
        if not frames:
            continue
        times = [int(f["timestamp_ms"]) for f in frames]
        ids = [int(f["frame_id"]) for f in frames]
        if any(b < a for a, b in zip(times, times[1:])) or any(b < a for a, b in zip(ids, ids[1:])):
            continue
        if times[0] <= packet.timestamp <= times[-1] and ids[0] <= packet.frame_id <= ids[-1]:
            result.append(window)
    return result


def exact_window(seq, windows):
    """Windows bound exactly by the AL/EI event sequence (protocol v2.1).

    The image window and the EI line share the FPGA per-event sequence, so this
    is a direct identity match, not a time/frame guess. Returns [] when seq is
    absent (v1/v2.0) or no window carries it.
    """
    if seq is None:
        return []
    return [w for w in windows if w.get('protocol') not in ('EGv2', 'HR') and w.get("seq") == seq]


def transaction_windows(packet, windows):
    """No time/seq fallback; ambiguous or conflicting identity is not bound."""
    same_id = [w for w in windows if w.get('protocol') in ('EGv2', 'HR') and w.get('identity') == packet.identity]
    if any(w.get('transaction') != packet.transaction for w in same_id):
        return [], '身份相同但事务上下文冲突，拒绝绑定'
    if not same_id:
        return [], '尚无同身份EGv2窗口（可稍后刷新；不推断丢包或成功）'
    if len(same_id) > 1:
        return same_id, '多个完整身份匹配，需人工核对采集来源'
    text = '完整身份及256bit事务精确关联：' + same_id[0]['status']
    if same_id[0].get('history_verdict'):
        text += '；' + evidence_state(same_id[0]) + '；' + history_details(same_id[0])
    return same_id, text


def candidate_summary(candidates):
    if not candidates:
        return "无候选（可能未采集/缺帧/时间不重合）"
    label = "单个候选，待核对会话" if len(candidates) == 1 else "多个候选，需人工选择"
    return label + "：" + ", ".join(w["path"].name for w in candidates)


def export_report(path, snapshot, windows, errors, *, session=None):
    if session is not None and Path(path).resolve() == Path(session.session_path).resolve():
        raise ValueError("Report output cannot overwrite the capture database")
    entries = session.events if session is not None else snapshot.events
    if session is None:
        scope = ["范围：当前监考台保留的最近事件（最多200条）及所选目录的图像窗口。",
                 "未使用持久化会话；清空、重启前的事件不在本报告中；目录可能包含多次运行。",
                 f"收到AL包总数：{snapshot.event_packets}；保留事件：{len(entries)}"]
        if getattr(snapshot, "persistence_error", None):
            scope.append(f"存档异常：{snapshot.persistence_error}")
    else:
        scope = ["范围：所选上位机采集会话中已提交到磁盘的全部AL接收记录；不受界面最近200条或清空列表影响。",
                 f"上位机采集会话ID：`{session.host_session_id}`",
                 f"存档文件：`{session.session_path}`",
                 f"开始 UTC：{session.started_at}；结束 UTC：{session.ended_at or '未记录正常结束（仍运行或异常退出）'}",
                 f"已知收到AL包总数：{session.event_packets}；已落盘：{len(entries)}；已知落盘失败：{session.persistence_failures}",
                 "采集会话不是FPGA启动/考试会话：一场考试可跨多次采集，一次采集也可包含复位或多场。",
                 "相同AL包按接收次数保留，不据此计算唯一违规数；上游丢失及异常退出前未提交的包无法由此证明完整性。"]
        if session.persistence_error:
            scope.append(f"存档异常：{session.persistence_error}")
    lines = ["# ExamGuard 监考记录", "",
             f"导出时间：{datetime.now(timezone.utc).isoformat()}", "",
             *scope, "",
             "examguard17起，ST含系统健康标志（相机/K230/证据忙/证据溢出）；0x00为正常。examguard19另追加同源考试计时。",
              "健康历史见末节ST接收记录；统计只覆盖已保存样本，不推断无ST期间健康。缺字段的旧ST可能经兼容解析为0，不能作健康证明。",
             "examguard15起，事件AL后可跟EI身份行（设备/启动/会话/事件UID）；无EI的是v1或EI丢失，不补造。",
              "身份持久性取决于位流：旧版为易失ID，PERSIST版采用EEPROM核验的boot；仅凭收到EI/ET不能推断已做掉电验收。RTC墙钟与单调源时间分开。",
              "PGv1未自动绑定告警，按旧seq/时间帧候选；EGv2按ET完整身份及事务精确关联，CRC/原始包/回放图像哈希复核，成功结果与完整像素缺一不可。", "",
             "## 事件时间线", "", "| 采集内接收序号 | 接收时间 UTC | 板内时间 ms | 阶段 | 风险 | 事件 | 事件UID | 设备/启动/会话 |",
             "|---:|---|---:|---|---|---|---:|---|"]
    for entry in entries:
        p = entry.packet
        identity = getattr(entry, "identity", None)
        uid = str(identity.uid) if identity else "—"
        who = f"{identity.device_id}/{identity.boot_id}/{identity.session_id}" if identity else "未收到EI"
        lines.append(f"| {entry.receipt_id} | {entry.received_at} | {p.timestamp} | {stage_name(p.stage_id)} | {risk_name(p.risk_level)} | {format_event(p.event_code)} | {uid} | {who} |")
    transactions = getattr(session if session is not None else snapshot, 'transactions', ())
    lines += ["", "## 同源事务事件 ET", "",
              "下列记录为源队列已接受的完整事务，与EG v2共享身份；不是旧AL/EI身份，也不表示图像窗口成功。",
              "传输复位可能取消证据；无结果不推断成功/失败。拒绝/取消计数见健康ST，逐事件取消与结果需图像结果协议。",
              f"本报告包含已保存ET接收记录：{len(transactions)}（重复接收保留，不当作唯一违规数）。",
              f"已知ET接收：{getattr(session if session is not None else snapshot, 'transaction_packets', 0)}；已知ET存档失败：{getattr(session, 'transaction_failures', 0)}。", "",
              "| ET接收序号 | UTC | 设备/启动/会话/UID | 源时间ms | 源 | 阶段/风险/事件 |",
              "|---:|---|---|---:|---:|---|"]
    for entry in transactions:
        p = entry.packet
        lines.append(f"| {entry.receipt_id} | {entry.received_at} | {'/'.join(map(str, p.identity))} | {p.timestamp} | {p.source} | {stage_name(p.stage_id)}/{risk_name(p.risk_level)}/{format_event(p.event_code)} |")
    lines += ['', '### ET精确证据关联', '']
    for entry in transactions:
        p = entry.packet
        matches, explanation = transaction_windows(p, windows)
        lines.append(f"- ET#{entry.receipt_id}：{explanation}" + ('；' + ', '.join(str(w['path']) for w in matches) if matches else ''))
    lines += ["", "## 事件候选证据", "",
              "仅按板内时间和帧号范围重合查找，未确认绑定。无会话ID，跨复位/多次运行可能重合；无候选不等于确定丢包。", ""]
    for entry in entries:
        p = entry.packet
        lines.append(f"- {p.timestamp} ms / 帧{p.frame_id} / {format_event(p.event_code)}："
                     + candidate_summary(candidate_windows(p, windows)))
    lines += ["", "## 图像证据", ""]
    for window in windows:
        frames = window["frames"]
        span = f"{frames[0]['timestamp_ms']}–{frames[-1]['timestamp_ms']} ms" if frames else "无帧"
        verdict = evidence_state(window)
        lines.append(f"- `{window['path']}`：{len(frames)}/{window['expected'] if window['expected'] is not None else '?'}帧，{verdict}，{span}")
        if window.get('history_verdict'):
            lines.append('  - ' + history_details(window))
    lines += ['', 'HR与像素按完整256bit事务关联；缺片、历史gap和unknown分开记录。联合完整仍不等于目标可见或整场连续覆盖。']
    if errors:
        lines += ["", "## 读取异常", *errors]
    if session is not None:
        from .health_history import report_lines
        lines += report_lines(session)
    source = session if session is not None else snapshot
    anchors = getattr(source, 'anchors', ())
    lines += ['', '## RTC时间锚（RA）', '',
              'RTC日历无时区；单调读区间包含仲裁等待和读取过程，另有秒量化/时钟漂移。以下记录不替换事件时间、不跨boot外推。',
              f"已保存RA记录：{len(anchors)}；已知接收：{getattr(source, 'anchor_packets', 0)}；存档失败：{getattr(source, 'anchor_failures', 0)}。",
              '| 接收序号 | 主机接收UTC | FPGA RTC锚 |', '|---:|---|---|']
    for entry in anchors:
        lines.append(f'| {entry.receipt_id} | {entry.received_at} | {entry.packet.text()} |')
    voice = getattr(source, 'voice', ())
    lines += ['', '## 语音交互与求助', '',
              f"保存VI状态：{len(voice)}；接收：{getattr(source, 'voice_packets', 0)}；存档失败：{getattr(source, 'voice_failures', 0)}。", '',
              '这些是交互状态快照，不是违规告警；发送处理请求不等于板上已处理。', '']
    for entry in voice:
        p = entry.packet
        lines.append(f'- {entry.received_at}：{p.device}/{p.boot}，考位{p.seat}，轮次{p.round_id}，'
                     f'信息修订{p.info_tag:016X}，准备状态{p.exam_state}，求助票{p.ticket}，'
                     f'待处理={p.help_pending}，处理回执={p.command_token}/{p.command_result}')
    maintenance = getattr(source, 'maintenance', ())
    lines += ['', '## 维护操作回执（MR）', '',
              '下列为板上回执接收记录，重复接收保留；失败/恢复错误/尝试写入分列。仅SET_RTC回执含来源偏移，不回填旧RA或替换事件单调时间。',
              f"已保存MR记录：{len(maintenance)}；已知接收：{getattr(source, 'maintenance_packets', 0)}；存档失败：{getattr(source, 'maintenance_failures', 0)}。",
              '| 接收序号 | 主机接收UTC | FPGA回执 | 写尝试 | 校时偏移/分钟 | 原始MR（含CRC） |',
              '|---:|---|---|---|---|---|']
    for entry in maintenance:
        p = entry.packet
        lines.append(f'| {entry.receipt_id} | {entry.received_at} | {p.text()} | {int(p.write_attempted)} | {p.rtc_offset_minutes if p.rtc_offset_minutes is not None else "未知"} | `{p.raw.hex().upper()}` |')
    monitors=getattr(source,'board_monitors',())
    lines+=['','## 板级监测（BM）','',
            '温度和电压为XADC片内读数，非外部供电质量测量；无效/陈旧记录不能当健康证明。',
            f"已保存BM记录：{len(monitors)}；接收：{getattr(source,'board_packets',0)}；存档失败：{getattr(source,'board_failures',0)}。"]
    lines += [f'- #{e.receipt_id} {e.received_at}：{e.packet.text()}' for e in monitors]
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")

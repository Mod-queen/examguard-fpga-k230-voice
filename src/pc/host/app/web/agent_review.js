'use strict';
const el = id => document.getElementById(id);
let csrf = '', busy = false;
let reviewRecord = null;
el('export-review').addEventListener('click', () => {
  if (!reviewRecord) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify(reviewRecord, null, 2) + '\n'], {type:'application/json;charset=utf-8'}));
  const link = document.createElement('a'); link.href = url; link.download = 'examguard_review_' + reviewRecord.queried_at_utc.replace(/[:+]/g, '_') + '.json';
  link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
async function api(path, data) {
  const response = await fetch(path, {
    method: data === undefined ? 'GET' : 'POST', credentials: 'same-origin',
    headers: data === undefined ? {} : {'Content-Type':'application/json', 'X-CSRF-Token':csrf},
    body: data === undefined ? undefined : JSON.stringify(data), signal: AbortSignal.timeout(65000)
  });
  const value = await response.json();
  if (!response.ok) { if (response.status === 401) showLogin(); throw new Error(value.error || '请求未完成'); }
  return value;
}
function showLogin() { csrf = ''; reviewRecord = null; el('export-review').disabled = true; el('login').hidden = false; el('workspace').hidden = true; el('mode').textContent = '尚未登录'; }
function message(who, text, user = false) {
  const box = document.createElement('div'); box.className = 'message' + (user ? ' user' : '');
  const title = document.createElement('strong'); title.textContent = who;
  const content = document.createElement('p'); content.textContent = text;
  box.append(title, content); el('messages').append(box); el('messages').scrollTop = el('messages').scrollHeight;
}
async function restore() {
  const session = await api('/api/session'); csrf = session.csrf;
  el('login').hidden = true; el('workspace').hidden = false;
  el('mode').textContent = session.mode === 'llm' ? '大模型API模式 · 查询后核验' : session.mode === 'opencode' ? 'OpenCode免费模型 · 查询后核验' : '本地工具演示 · 未接大模型';
  el('source').textContent = session.source + ' / ' + session.scope;
  el('scope').textContent = session.public ? '评审访问入口' : '本机验收入口 · 公开链接需要部署';
  if (!el('messages').childNodes.length) message('复核助手', '可查询最近事件、证据状态和系统健康。查询范围为当前选定存档，识别结果需要人工看图复核。');
}
el('login-form').addEventListener('submit', async event => {
  event.preventDefault(); el('login-error').textContent = '';
  try { await api('/api/login', {username:el('username').value, password:el('password').value}); el('password').value = ''; await restore(); }
  catch (error) { el('login-error').textContent = error.message; }
});
el('logout').addEventListener('click', async () => { try { await api('/api/logout', {}); } finally {
  showLogin(); el('messages').replaceChildren(); el('evidence').replaceChildren(); el('verified').textContent = '尚未执行查询。'; el('trace').textContent = '';
}});
function renderEvidence(trace) {
  const events = new Map(), states = new Map(), images = new Map();
  trace.forEach(call => {
    const data = call.result;
    if (call.name === 'get_recent_events') (data.events || []).forEach(item => events.set(item.event_ref, item));
    if (call.name === 'check_evidence_status' && data.event_ref) states.set(data.event_ref, data);
    if (call.name === 'get_image_path' && data.event_ref) images.set(data.event_ref, data.images || []);
  });
  el('evidence').replaceChildren();
  events.forEach((event, ref) => {
    const card = document.createElement('div'); card.className = 'event';
    const title = document.createElement('strong'); title.textContent = event.event + ' · 疑似';
    const id = document.createElement('small'); id.textContent = 'UID ' + event.event_uid + ' / 设备 ' + event.device + ' / 启动 ' + event.boot;
    const stamp = document.createElement('small'); stamp.textContent = 'PC接收：' + event.received_at;
    const state = document.createElement('p'); state.textContent = states.has(ref) ? states.get(ref).status_label : '尚未核验证据';
    card.append(title, id, stamp, state);
    const frames = images.get(ref) || [];
    if (frames.length) {
      const image = document.createElement('img'); image.alt = '校验通过的原始证据帧';
      const caption = document.createElement('small');
      function show(frame) { image.src = '/api/image?event_ref=' + encodeURIComponent(ref) + '&index=' + frame.frame_index; caption.textContent = '帧 ' + frame.frame_index + ' / 源时间 ' + frame.timestamp_ms + ' ms'; }
      image.addEventListener('error', () => { caption.textContent = '图像未通过重新校验或登录已过期，请重新查询。'; });
      show(frames[0]); card.append(image, caption);
      const selector = document.createElement('div'); selector.className = 'frames';
      frames.forEach(frame => { const button = document.createElement('button'); button.type = 'button'; button.className = 'secondary'; button.textContent = '帧 ' + frame.frame_index; button.addEventListener('click', () => show(frame)); selector.append(button); });
      card.append(selector);
    }
    el('evidence').append(card);
  });
  if (!events.size) { const p = document.createElement('p'); p.className = 'empty'; p.textContent = '本次没有可展示的ET事件；请查看查询范围和核验记录。'; el('evidence').append(p); }
}
async function ask(question) {
  if (busy || !question.trim()) return;
  busy = true; el('send').disabled = true; el('question').value = '';
  reviewRecord = null; el('export-review').disabled = true;
  message('老师', question, true); el('query-state').textContent = '正在调用只读工具…';
  try {
    const reply = await api('/api/ask', {question});
    reviewRecord = reply.review_record; el('export-review').disabled = !reviewRecord;
    message(['大模型工具调用', 'OpenCode免费模型工具调用'].includes(reply.mode) ? '模型说明（以核验记录为准）' : reply.mode, reply.answer);
    el('verified').textContent = reply.verified; el('trace').textContent = JSON.stringify(reply.trace, null, 2);
    renderEvidence(reply.trace); el('query-state').textContent = reply.mode +
      (reply.model_route?.actual_model ? ' · ' + reply.model_route.actual_model : '');
  } catch (error) { message('查询未完成', error.message); el('query-state').textContent = '查询未完成，未生成新的核验结论。'; }
  finally { busy = false; el('send').disabled = false; }
}
el('ask-form').addEventListener('submit', event => { event.preventDefault(); ask(el('question').value); });
document.querySelectorAll('[data-question]').forEach(button => button.addEventListener('click', () => ask(button.dataset.question)));
restore().catch(() => showLogin());

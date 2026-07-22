import { useMemo, useState } from 'react'
import {
  loadCodes, loadEmails, loadRoster, randomCode, saveCodes, saveEmails, saveRoster,
} from '../../admin/adminData'
import type { EmailLogEntry, InviteCode, RosterUser } from '../../admin/adminData'

const REGIONS = ['UK', 'FR', 'DE', 'JP'] as const

function emailBody(code: string) {
  return `Hi,

You're invited to join our Model Evaluation Studio and rate AI-generated results.

Your personal invite code: ${code}
Open the app, enter the code and sign in with your email or Google account.

Thanks for helping us build better models!
— The Research Team`
}

export default function Roster() {
  const [roster, setRoster] = useState<RosterUser[]>(loadRoster)
  const [emails, setEmails] = useState<EmailLogEntry[]>(loadEmails)
  const [input, setInput] = useState('')
  const [region, setRegion] = useState<(typeof REGIONS)[number]>('UK')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [preview, setPreview] = useState(false)
  const [toast, setToast] = useState('')

  const update = (next: RosterUser[]) => { setRoster(next); saveRoster(next) }

  const importUsers = () => {
    const parts = input.split(/[\s,;，；]+/).map((s) => s.trim()).filter(Boolean)
    const valid = parts.filter((p) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(p))
    const existing = new Set(roster.map((u) => u.email.toLowerCase()))
    const fresh = valid
      .filter((e) => !existing.has(e.toLowerCase()))
      .map((email) => ({ id: `${Date.now()}-${email}`, email, region }))
    update([...roster, ...fresh])
    setInput('')
    setToast(`已导入 ${fresh.length} 人(去重后)`)
    setTimeout(() => setToast(''), 2500)
  }

  const toggleSelect = (id: string) => {
    const next = new Set(selected)
    next.has(id) ? next.delete(id) : next.add(id)
    setSelected(next)
  }
  const selectAllUnsent = () =>
    setSelected(new Set(roster.filter((u) => !u.sentAt).map((u) => u.id)))

  const targets = useMemo(() => roster.filter((u) => selected.has(u.id)), [roster, selected])

  // Assign each target a fresh single-use code, log one email per user (mock
  // send — real impl goes through the mail service, PRD 5.4.1).
  const sendInvites = () => {
    const codes: InviteCode[] = loadCodes()
    const now = new Date().toISOString()
    const nextRoster = roster.map((u) => {
      if (!selected.has(u.id)) return u
      let code = u.code
      if (!code) {
        code = randomCode('INV')
        codes.unshift({ code, maxUse: 1, used: 0, status: 'active', assignedTo: u.email, createdAt: now })
      }
      return { ...u, code, sentAt: now }
    })
    saveCodes(codes)
    update(nextRoster)
    const log: EmailLogEntry = {
      at: now,
      to: targets.map((t) => t.email),
      subject: 'Invitation: rate AI results in Model Evaluation Studio',
    }
    const nextEmails = [log, ...emails]
    setEmails(nextEmails)
    saveEmails(nextEmails)
    setSelected(new Set())
    setPreview(false)
    setToast(`已向 ${log.to.length} 位用户发送邀请邮件(模拟)`)
    setTimeout(() => setToast(''), 3000)
  }

  return (
    <div>
      <div className="card admin-form">
        <h3>导入用户名单</h3>
        <textarea
          className="feedback"
          rows={3}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="粘贴邮箱,支持换行/逗号/分号分隔,自动去重&#10;例如: alice@mail.com, bob@mail.co.uk"
        />
        <div className="admin-form-row">
          <label>地区
            <select value={region} onChange={(e) => setRegion(e.target.value as any)}>
              {REGIONS.map((r) => <option key={r}>{r}</option>)}
            </select>
          </label>
          <button className="btn btn-primary" onClick={importUsers} disabled={!input.trim()}>导入</button>
        </div>
      </div>

      <div className="admin-page-head">
        <p className="hint">共 {roster.length} 人 · 已选 {selected.size} 人</p>
        <div className="admin-actions">
          <button className="btn btn-ghost btn-sm" onClick={selectAllUnsent}>全选未发送</button>
          <button className="btn btn-primary btn-sm" disabled={selected.size === 0} onClick={() => setPreview(true)}>
            批量发送邮件 + 邀请码
          </button>
        </div>
      </div>

      <div className="card admin-table-wrap">
        <table className="admin-table">
          <thead>
            <tr><th></th><th>邮箱</th><th>地区</th><th>邀请码</th><th>发送状态</th><th></th></tr>
          </thead>
          <tbody>
            {roster.length === 0 && (
              <tr><td colSpan={6} className="empty">名单为空,先在上方导入邮箱</td></tr>
            )}
            {roster.map((u) => (
              <tr key={u.id}>
                <td><input type="checkbox" checked={selected.has(u.id)} onChange={() => toggleSelect(u.id)} /></td>
                <td>{u.email}</td>
                <td>{u.region}</td>
                <td className="mono">{u.code ?? '—'}</td>
                <td>
                  {u.sentAt
                    ? <span className="badge badge-ok">已发送 {new Date(u.sentAt).toLocaleDateString()}</span>
                    : <span className="badge badge-used">未发送</span>}
                </td>
                <td>
                  <button className="btn btn-ghost btn-xs" onClick={() => update(roster.filter((x) => x.id !== u.id))}>移除</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {emails.length > 0 && (
        <div className="card">
          <h3>发送记录</h3>
          {emails.map((e, i) => (
            <div className="redemption-row" key={i}>
              <span>{e.subject}</span>
              <span className="hint">{e.to.length} 人 · {new Date(e.at).toLocaleString()}</span>
            </div>
          ))}
        </div>
      )}

      {preview && (
        <div className="modal-backdrop" onClick={() => setPreview(false)}>
          <div className="modal admin-mail-modal" onClick={(e) => e.stopPropagation()}>
            <h3>邮件预览({targets.length} 位收件人)</h3>
            <p className="hint">收件人:{targets.slice(0, 3).map((t) => t.email).join('、')}{targets.length > 3 ? ` 等 ${targets.length} 人` : ''}</p>
            <p><strong>主题:</strong>Invitation: rate AI results in Model Evaluation Studio</p>
            <pre className="mail-body">{emailBody(targets[0]?.code ?? 'INV-XXXXXX(发送时为每人生成专属码)')}</pre>
            <div className="submit-row">
              <button className="btn btn-ghost" onClick={() => setPreview(false)}>取消</button>
              <button className="btn btn-primary grow" onClick={sendInvites}>确认发送(模拟)</button>
            </div>
          </div>
        </div>
      )}
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}

import { useState } from 'react'
import { loadCodes, randomCode, saveCodes } from '../../admin/adminData'
import type { InviteCode } from '../../admin/adminData'

export default function Invites() {
  const [codes, setCodes] = useState<InviteCode[]>(loadCodes)
  const [count, setCount] = useState(10)
  const [prefix, setPrefix] = useState('INV')
  const [maxUse, setMaxUse] = useState(1)

  const update = (next: InviteCode[]) => { setCodes(next); saveCodes(next) }

  const generate = () => {
    const now = new Date().toISOString()
    const fresh: InviteCode[] = []
    const existing = new Set(codes.map((c) => c.code))
    while (fresh.length < count) {
      const code = randomCode(prefix.trim().toUpperCase() || 'INV')
      if (existing.has(code)) continue
      existing.add(code)
      fresh.push({ code, maxUse, used: 0, status: 'active', createdAt: now })
    }
    update([...fresh, ...codes])
  }

  const voidCode = (code: string) =>
    update(codes.map((c) => (c.code === code ? { ...c, status: 'void' as const } : c)))

  const copyAll = () => {
    const unused = codes.filter((c) => c.status === 'active' && c.used === 0).map((c) => c.code)
    navigator.clipboard?.writeText(unused.join('\n'))
  }

  const stats = {
    total: codes.length,
    unused: codes.filter((c) => c.status === 'active' && c.used === 0).length,
    used: codes.filter((c) => c.used > 0).length,
    void: codes.filter((c) => c.status === 'void').length,
  }

  return (
    <div>
      <div className="card admin-form">
        <h3>批量生成邀请码</h3>
        <div className="admin-form-row">
          <label>数量
            <input type="number" min={1} max={200} value={count} onChange={(e) => setCount(Number(e.target.value))} />
          </label>
          <label>前缀
            <input value={prefix} maxLength={8} onChange={(e) => setPrefix(e.target.value)} />
          </label>
          <label>每码可用次数
            <input type="number" min={1} max={10} value={maxUse} onChange={(e) => setMaxUse(Number(e.target.value))} />
          </label>
          <button className="btn btn-primary" onClick={generate}>生成</button>
          <button className="btn btn-ghost" onClick={copyAll} disabled={stats.unused === 0}>复制未用的码</button>
        </div>
        <p className="hint">默认一码一人(PRD 5.4.1)。生成的码立即可在 C 端登录页使用。</p>
      </div>

      <div className="stat-row admin-stats">
        <div className="card stat"><strong>{stats.total}</strong><span>总数</span></div>
        <div className="card stat"><strong>{stats.unused}</strong><span>未使用</span></div>
        <div className="card stat"><strong>{stats.used}</strong><span>已使用</span></div>
        <div className="card stat"><strong>{stats.void}</strong><span>已作废</span></div>
      </div>

      <div className="card admin-table-wrap">
        <table className="admin-table">
          <thead>
            <tr><th>邀请码</th><th>使用</th><th>状态</th><th>分配给</th><th>创建时间</th><th></th></tr>
          </thead>
          <tbody>
            {codes.length === 0 && (
              <tr><td colSpan={6} className="empty">还没有邀请码,先在上方生成一批</td></tr>
            )}
            {codes.map((c) => (
              <tr key={c.code}>
                <td className="mono">{c.code}</td>
                <td>{c.used}/{c.maxUse}</td>
                <td>
                  {c.status === 'void'
                    ? <span className="badge badge-void">已作废</span>
                    : c.used >= c.maxUse
                      ? <span className="badge badge-used">已用完</span>
                      : <span className="badge badge-ok">可用</span>}
                </td>
                <td>{c.assignedTo ?? '—'}</td>
                <td className="hint">{new Date(c.createdAt).toLocaleString()}</td>
                <td>
                  {c.status === 'active' && (
                    <button className="btn btn-ghost btn-xs" onClick={() => voidCode(c.code)}>作废</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

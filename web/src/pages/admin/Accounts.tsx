import { useState } from 'react'
import { loadAdmins, saveAdmins } from '../../admin/adminData'
import type { AdminAccount } from '../../admin/adminData'

export default function Accounts({ currentEmail }: { currentEmail: string }) {
  const [admins, setAdmins] = useState<AdminAccount[]>(loadAdmins)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [toast, setToast] = useState('')

  const update = (next: AdminAccount[]) => { setAdmins(next); saveAdmins(next) }
  const flash = (msg: string) => { setToast(msg); setTimeout(() => setToast(''), 2500) }

  const create = () => {
    setError('')
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { setError('请输入有效邮箱'); return }
    if (password.length < 3) { setError('密码至少 3 位(正式环境应有强度要求)'); return }
    if (admins.some((a) => a.email.toLowerCase() === email.trim().toLowerCase())) { setError('该邮箱已存在'); return }
    update([...admins, {
      email: email.trim(), password, role: 'ops', status: 'active',
      createdAt: new Date().toISOString(),
    }])
    setEmail(''); setPassword('')
    flash('账号已创建,可用于登录管理后台')
  }

  const toggle = (target: AdminAccount) => {
    if (target.role === 'super') return
    update(admins.map((a) => (a.email === target.email
      ? { ...a, status: a.status === 'active' ? 'disabled' as const : 'active' as const }
      : a)))
  }

  const resetPassword = (target: AdminAccount) => {
    const next = window.prompt(`为 ${target.email} 设置新密码:`)
    if (!next) return
    update(admins.map((a) => (a.email === target.email ? { ...a, password: next } : a)))
    flash('密码已重置')
  }

  return (
    <div>
      <div className="card admin-form">
        <h3>创建管理员账号</h3>
        <div className="admin-form-row">
          <label>邮箱
            <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="ops@example.com" />
          </label>
          <label>初始密码
            <input value={password} onChange={(e) => setPassword(e.target.value)} />
          </label>
          <button className="btn btn-primary" onClick={create}>创建</button>
        </div>
        <p className="hint">新账号为运营管理员角色,可使用除「账号管理」外的全部功能。正式环境首次登录需强制改密(PRD 5.10.1)。</p>
        {error && <p className="error">{error}</p>}
      </div>

      <div className="card admin-table-wrap">
        <table className="admin-table">
          <thead>
            <tr><th>邮箱</th><th>角色</th><th>状态</th><th>创建时间</th><th></th></tr>
          </thead>
          <tbody>
            {admins.map((a) => (
              <tr key={a.email}>
                <td>{a.email}{a.email === currentEmail && <span className="hint">(当前登录)</span>}</td>
                <td>{a.role === 'super'
                  ? <span className="badge badge-ok">超级管理员</span>
                  : <span className="badge badge-used">运营管理员</span>}</td>
                <td>{a.status === 'active'
                  ? <span className="badge badge-ok">启用</span>
                  : <span className="badge badge-void">已停用</span>}</td>
                <td className="hint">{new Date(a.createdAt).toLocaleString()}</td>
                <td className="admin-actions">
                  {a.role !== 'super' && (
                    <>
                      <button className="btn btn-ghost btn-xs" onClick={() => toggle(a)}>
                        {a.status === 'active' ? '停用' : '启用'}
                      </button>
                      <button className="btn btn-ghost btn-xs" onClick={() => resetPassword(a)}>重置密码</button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}

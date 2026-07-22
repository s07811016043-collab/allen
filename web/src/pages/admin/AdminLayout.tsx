import { Navigate, NavLink, Route, Routes, useNavigate } from 'react-router-dom'
import { ADMIN_EMAIL, K_ADMIN_SESSION, load } from '../../admin/adminData'
import Invites from './Invites'
import DataMgmt from './DataMgmt'
import Roster from './Roster'
import Accounts from './Accounts'

export default function AdminLayout() {
  const nav = useNavigate()
  const session = load<{ email: string; role?: 'super' | 'ops' } | null>(K_ADMIN_SESSION, null)
  if (!session) return <Navigate to="/admin/login" replace />
  const isSuper = session.role === 'super' || (session.role == null && session.email === ADMIN_EMAIL)

  return (
    <div className="admin">
      <header className="admin-topbar">
        <span className="topbar-title">调研平台 · 管理后台</span>
        <div className="admin-topbar-right">
          <span className="hint">{session.email}</span>
          <button
            className="btn btn-ghost btn-sm"
            onClick={() => { localStorage.removeItem(K_ADMIN_SESSION); nav('/admin/login') }}
          >
            退出
          </button>
        </div>
      </header>
      <nav className="admin-tabs">
        <NavLink to="/admin/invites">邀请码</NavLink>
        <NavLink to="/admin/data">模型数据</NavLink>
        <NavLink to="/admin/roster">用户名单</NavLink>
        {isSuper && <NavLink to="/admin/accounts">账号管理</NavLink>}
      </nav>
      <div className="admin-body">
        <Routes>
          <Route path="invites" element={<Invites />} />
          <Route path="data" element={<DataMgmt />} />
          <Route path="roster" element={<Roster />} />
          {isSuper && <Route path="accounts" element={<Accounts currentEmail={session.email} />} />}
          <Route path="*" element={<Navigate to="/admin/invites" replace />} />
        </Routes>
      </div>
    </div>
  )
}

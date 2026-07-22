import { Navigate, NavLink, Route, Routes, useNavigate } from 'react-router-dom'
import { K_ADMIN_SESSION, load } from '../../admin/adminData'
import Invites from './Invites'
import DataMgmt from './DataMgmt'
import Roster from './Roster'

export default function AdminLayout() {
  const nav = useNavigate()
  const session = load<{ email: string } | null>(K_ADMIN_SESSION, null)
  if (!session) return <Navigate to="/admin/login" replace />

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
      </nav>
      <div className="admin-body">
        <Routes>
          <Route path="invites" element={<Invites />} />
          <Route path="data" element={<DataMgmt />} />
          <Route path="roster" element={<Roster />} />
          <Route path="*" element={<Navigate to="/admin/invites" replace />} />
        </Routes>
      </div>
    </div>
  )
}

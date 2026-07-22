import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ADMIN_EMAIL, ADMIN_PASSWORD, K_ADMIN_SESSION } from '../../admin/adminData'

export default function AdminLogin() {
  const nav = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')

  const submit = () => {
    if (email.trim().toLowerCase() === ADMIN_EMAIL && password === ADMIN_PASSWORD) {
      localStorage.setItem(K_ADMIN_SESSION, JSON.stringify({ email: ADMIN_EMAIL, at: Date.now() }))
      nav('/admin/invites')
    } else {
      setError('邮箱或密码不正确')
    }
  }

  return (
    <div className="login-page">
      <Link to="/login" className="back-link">← 返回用户登录</Link>
      <div className="login-hero">
        <h1>调研平台 · 管理后台</h1>
        <p>仅限内部运营与项目管理员使用</p>
      </div>
      <div className="card login-card">
        <label className="field">
          <span>管理员邮箱</span>
          <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="admin@example.com" />
        </label>
        <label className="field">
          <span>密码</span>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && submit()}
          />
        </label>
        <button className="btn btn-primary" onClick={submit}>登录</button>
        {error && <p className="error">{error}</p>}
      </div>
    </div>
  )
}

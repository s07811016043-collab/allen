import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { useStore } from './store'
import Login from './pages/Login'
import Home from './pages/Home'
import RateHighlight from './pages/RateHighlight'
import RateAesthetic from './pages/RateAesthetic'
import RateKeyword from './pages/RateKeyword'
import Rewards from './pages/Rewards'
import Profile from './pages/Profile'
import AdminLogin from './pages/admin/AdminLogin'
import AdminLayout from './pages/admin/AdminLayout'
import { BottomNav, TopBar } from './components'

function RequireAuth({ children }: { children: JSX.Element }) {
  const { user } = useStore()
  const loc = useLocation()
  if (!user) return <Navigate to="/login" state={{ from: loc }} replace />
  return children
}

export default function App() {
  const { user } = useStore()
  const loc = useLocation()
  const isAdmin = loc.pathname.startsWith('/admin')

  if (isAdmin) {
    return (
      <Routes>
        <Route path="/admin/login" element={<AdminLogin />} />
        <Route path="/admin/*" element={<AdminLayout />} />
      </Routes>
    )
  }

  return (
    <div className="app">
      <TopBar />
      <main className="main">
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/" element={<RequireAuth><Home /></RequireAuth>} />
          <Route path="/rate/highlight" element={<RequireAuth><RateHighlight /></RequireAuth>} />
          <Route path="/rate/aesthetic" element={<RequireAuth><RateAesthetic /></RequireAuth>} />
          <Route path="/rate/keyword" element={<RequireAuth><RateKeyword /></RequireAuth>} />
          <Route path="/rewards" element={<RequireAuth><Rewards /></RequireAuth>} />
          <Route path="/profile" element={<RequireAuth><Profile /></RequireAuth>} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
      {user && <BottomNav />}
    </div>
  )
}

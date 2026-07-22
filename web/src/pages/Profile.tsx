import { useNavigate } from 'react-router-dom'
import { LangSwitcher } from '../components'
import { useStore } from '../store'

export default function Profile() {
  const { t, user, logout, ratings, points } = useStore()
  const nav = useNavigate()
  const valid = ratings.filter((r) => !r.skipped).length

  const onDelete = () => {
    if (!window.confirm(t('deleteConfirm'))) return
    localStorage.clear()
    logout()
    nav('/login')
  }

  return (
    <div className="page">
      <h2>{t('profile')}</h2>
      <div className="card profile-card">
        <div className="avatar">{user?.email[0]?.toUpperCase()}</div>
        <div>
          <strong>{user?.email}</strong>
          <small className="hint block-hint">{t('inviteCode')}: {user?.inviteCode}</small>
        </div>
      </div>

      <div className="stat-row">
        <div className="card stat"><strong>⭐ {points}</strong><span>{t('myPoints')}</span></div>
        <div className="card stat"><strong>{valid}</strong><span>{t('ratingsCount')}</span></div>
      </div>

      <div className="card setting-row">
        <div>
          <strong>{t('language')}</strong>
          <small className="hint block-hint">{t('languageAuto')}</small>
        </div>
        <LangSwitcher />
      </div>

      <button className="btn btn-ghost block" onClick={() => { logout(); nav('/login') }}>{t('signOut')}</button>
      <button className="btn btn-danger block" onClick={onDelete}>{t('deleteAccount')}</button>
    </div>
  )
}

import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useStore } from '../store'
import { consumeInvite, isValidInvite } from '../admin/adminData'

export default function Login() {
  const { t, login } = useStore()
  const nav = useNavigate()
  const [invite, setInvite] = useState('')
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [codeSent, setCodeSent] = useState(false)
  const [consent, setConsent] = useState(false)
  const [error, setError] = useState('')

  const checkInvite = () => {
    if (!isValidInvite(invite)) {
      setError(t('inviteInvalid'))
      return false
    }
    return true
  }

  const finish = (userEmail: string) => {
    if (!consent) { setError(t('consentRequired')); return }
    if (!checkInvite()) return
    consumeInvite(invite)
    login(userEmail, invite.trim().toUpperCase())
    nav('/')
  }

  const submitEmail = () => {
    setError('')
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { setError(t('emailInvalid')); return }
    if (!codeSent) { if (checkInvite() && consent) setCodeSent(true); else if (!consent) setError(t('consentRequired')); return }
    if (!/^\d{6}$/.test(code)) { setError(t('codeInvalid')); return }
    finish(email)
  }

  return (
    <div className="login-page">
      <div className="login-hero">
        <h1>{t('appName')}</h1>
        <p>{t('tagline')}</p>
      </div>
      <div className="card login-card">
        <label className="field">
          <span>{t('inviteCode')}</span>
          <input value={invite} onChange={(e) => setInvite(e.target.value)} placeholder={t('invitePlaceholder')} />
        </label>

        <button className="btn btn-google" onClick={() => { setError(''); finish('google-user@gmail.com') }}>
          <span className="g-logo">G</span> {t('signInGoogle')}
        </button>

        <div className="divider"><span>{t('or')}</span></div>

        <label className="field">
          <span>{t('email')}</span>
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder={t('emailPlaceholder')} />
        </label>
        {codeSent && (
          <label className="field">
            <span>{t('verifyCode')}</span>
            <input inputMode="numeric" maxLength={6} value={code} onChange={(e) => setCode(e.target.value)} placeholder={t('codePlaceholder')} />
            <small className="hint">{t('codeHint')}</small>
          </label>
        )}
        <button className="btn btn-primary" onClick={submitEmail}>
          {codeSent ? t('signIn') : t('sendCode')}
        </button>

        <label className="consent">
          <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
          <span>{t('consent')}</span>
        </label>
        {error && <p className="error">{error}</p>}
      </div>
      <p className="admin-entry"><Link to="/admin/login">Admin</Link></p>
    </div>
  )
}

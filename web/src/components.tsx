import { useEffect, useRef, useState } from 'react'
import { NavLink } from 'react-router-dom'
import { LANGS } from './i18n'
import { useStore } from './store'
import type { MediaRef } from './mock'

export function Likert({ value, onChange, question }: {
  value?: number
  onChange: (v: number) => void
  question: string
}) {
  const { t } = useStore()
  return (
    <div className="likert">
      <p className="likert-q">{question}</p>
      <div className="likert-row">
        {[1, 2, 3, 4, 5].map((v) => (
          <button
            key={v}
            type="button"
            className={`likert-btn ${value === v ? 'active' : ''}`}
            onClick={() => onChange(v)}
          >
            <span className="likert-num">{v}</span>
            <span className="likert-anchor">{t(`anchor${v}`)}</span>
          </button>
        ))}
      </div>
    </div>
  )
}

// Watermarked media tile (PRD 5.4.2 anti-leak): overlays the rater's hash and
// blocks the context menu. Videos report watch progress for the ≥50% gate.
export function MediaTile({ media, watermark, selected, onClick, onWatched, big }: {
  media: MediaRef
  watermark: string
  selected?: boolean
  onClick?: () => void
  onWatched?: (id: string) => void
  big?: boolean
}) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const [done, setDone] = useState(false)

  useEffect(() => {
    const el = videoRef.current
    if (!el || !onWatched) return
    const check = () => {
      if (!done && el.duration > 0 && (el.currentTime / el.duration >= 0.5 || el.ended)) {
        setDone(true)
        onWatched(media.id)
      }
    }
    el.addEventListener('timeupdate', check)
    el.addEventListener('ended', check)
    return () => {
      el.removeEventListener('timeupdate', check)
      el.removeEventListener('ended', check)
    }
  }, [done, media.id, onWatched])

  return (
    <div
      className={`tile ${big ? 'tile-big' : ''} ${selected ? 'tile-selected' : ''} ${onClick ? 'tile-clickable' : ''}`}
      onClick={onClick}
      onContextMenu={(e) => e.preventDefault()}
    >
      {media.type === 'photo' ? (
        <img src={media.url} alt="" loading="lazy" draggable={false} />
      ) : (
        <video ref={videoRef} src={media.url} poster={media.poster} controls muted playsInline preload="none" />
      )}
      {media.type === 'video' && media.durationSec && (
        <span className="tile-duration">{media.durationSec}s</span>
      )}
      {selected && <span className="tile-check">✓</span>}
      <span className="watermark">{watermark}</span>
    </div>
  )
}

export function ProgressBar({ done, total }: { done: number; total: number }) {
  const { t } = useStore()
  return (
    <div className="progress-wrap">
      <div className="progress-label">{t('progress')}: {done}/{total}</div>
      <div className="progress-track"><div className="progress-fill" style={{ width: `${(done / total) * 100}%` }} /></div>
    </div>
  )
}

export function LangSwitcher() {
  const { lang, setLang } = useStore()
  return (
    <select className="lang-select" value={lang} onChange={(e) => setLang(e.target.value as any)} aria-label="Language">
      {LANGS.map((l) => <option key={l.code} value={l.code}>{l.label}</option>)}
    </select>
  )
}

export function BottomNav() {
  const { t } = useStore()
  return (
    <nav className="bottom-nav">
      <NavLink to="/" end>{t('home')}</NavLink>
      <NavLink to="/rewards">{t('rewards')}</NavLink>
      <NavLink to="/profile">{t('profile')}</NavLink>
    </nav>
  )
}

export function TopBar({ title }: { title?: string }) {
  const { t, points, user } = useStore()
  return (
    <header className="topbar">
      <span className="topbar-title">{title ?? t('appName')}</span>
      <div className="topbar-right">
        {user && <span className="points-badge">⭐ {points} {t('points')}</span>}
        <LangSwitcher />
      </div>
    </header>
  )
}

// Stable per-user watermark text (hash stand-in for user_id hash)
export function watermarkOf(email: string | undefined) {
  if (!email) return 'guest'
  let h = 0
  for (const c of email) h = (h * 31 + c.charCodeAt(0)) >>> 0
  return `#${h.toString(16).slice(0, 8)}`
}

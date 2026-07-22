import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Likert } from '../components'
import { useStore } from '../store'

export function Completed() {
  const { t } = useStore()
  return (
    <div className="page center-page">
      <h2>{t('completedTitle')}</h2>
      <p className="sub">{t('completedBody')}</p>
      <Link to="/" className="btn btn-primary">{t('backHome')}</Link>
    </div>
  )
}

export function DimensionList({ dims, scores, onScore }: {
  dims: readonly string[]
  scores: Record<string, number>
  onScore: (key: string, v: number) => void
}) {
  const { t } = useStore()
  return (
    <div className="dims">
      {dims.map((d) => (
        <Likert key={d} question={t(d)} value={scores[d]} onChange={(v) => onScore(d, v)} />
      ))}
    </div>
  )
}

export function SubmitBar({ canSubmit, blockReason, onSubmit, onSkip, freeText, setFreeText }: {
  canSubmit: boolean
  blockReason?: string
  onSubmit: () => void
  onSkip: (reason: string) => void
  freeText: string
  setFreeText: (s: string) => void
}) {
  const { t } = useStore()
  const [showSkip, setShowSkip] = useState(false)
  const [warn, setWarn] = useState('')
  return (
    <div className="submit-bar">
      <textarea
        className="feedback"
        maxLength={200}
        value={freeText}
        onChange={(e) => setFreeText(e.target.value)}
        placeholder={t('feedbackPlaceholder')}
      />
      {warn && <p className="error">{warn}</p>}
      <div className="submit-row">
        <button className="btn btn-ghost" onClick={() => setShowSkip(true)}>{t('skip')}</button>
        <button
          className="btn btn-primary grow"
          onClick={() => {
            if (!canSubmit) { setWarn(blockReason ?? t('answerAll')); return }
            setWarn('')
            onSubmit()
            window.scrollTo({ top: 0 })
          }}
        >
          {t('submit')}
        </button>
      </div>
      {showSkip && (
        <div className="modal-backdrop" onClick={() => setShowSkip(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h3>{t('skipReasonTitle')}</h3>
            {(['skipReason1', 'skipReason2', 'skipReason3'] as const).map((r) => (
              <button key={r} className="btn btn-ghost block" onClick={() => { setShowSkip(false); onSkip(r); window.scrollTo({ top: 0 }) }}>
                {t(r)}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

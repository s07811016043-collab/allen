import { useState } from 'react'
import { MediaTile, ProgressBar, watermarkOf } from '../components'
import { DIMENSIONS, highlightItems } from '../mock'
import { useStore } from '../store'
import { useRating } from './useRating'
import { Completed, DimensionList, SubmitBar } from './RateShared'

export default function RateHighlight() {
  const { t, user } = useStore()
  const r = useRating('highlight', highlightItems)
  const [selection, setSelection] = useState<string[]>([])
  const [watched, setWatched] = useState<Set<string>>(new Set())
  const wm = watermarkOf(user?.email)

  if (!r.current) return <Completed />
  const item = r.current
  const dims = DIMENSIONS.highlight

  // PRD 5.5.2 — every video in the highlight result must be ≥50% watched
  const videos = item.highlightResult.filter((m) => m.type === 'video')
  const videosOk = videos.every((v) => watched.has(v.id))
  const dimsOk = dims.every((d) => r.scores[d] != null)

  const toggleSelect = (id: string) =>
    setSelection((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]))

  const next = () => { setSelection([]); setWatched(new Set()) }

  return (
    <div className="page">
      <ProgressBar done={r.done} total={r.total} />

      <h3 className="section-title">{t('modelPicked')}</h3>
      <div className="grid grid-3">
        {item.highlightResult.map((m, i) => (
          <div className="ranked" key={m.id}>
            <span className="rank-badge">{i + 1}</span>
            <MediaTile media={m} watermark={wm} onWatched={(id) => setWatched((s) => new Set(s).add(id))} big />
          </div>
        ))}
      </div>
      {videos.length > 0 && !videosOk && <p className="notice">▶ {t('watchFirst')}</p>}

      <h3 className="section-title">{t('sourceSet')}</h3>
      <p className="hint">{t('betterPickHint')}</p>
      <div className="grid grid-4">
        {item.sourceSet.map((m) => (
          <MediaTile
            key={m.id}
            media={m}
            watermark={wm}
            selected={selection.includes(m.id)}
            onClick={m.type === 'photo' ? () => toggleSelect(m.id) : undefined}
          />
        ))}
      </div>

      <DimensionList dims={dims} scores={r.scores} onScore={(k, v) => r.setScores({ ...r.scores, [k]: v })} />
      <SubmitBar
        canSubmit={dimsOk && videosOk}
        blockReason={!videosOk ? t('watchFirst') : undefined}
        onSubmit={() => { r.submit({ userSelection: selection }); next() }}
        onSkip={(reason) => { r.skip(reason); next() }}
        freeText={r.freeText}
        setFreeText={r.setFreeText}
      />
    </div>
  )
}

import { useState } from 'react'
import { MediaTile, ProgressBar, watermarkOf } from '../components'
import { DIMENSIONS, keywordItems } from '../mock'
import { useStore } from '../store'
import { useRating } from './useRating'
import { Completed, DimensionList, SubmitBar } from './RateShared'

type Mark = 'relevant' | 'partial' | 'irrelevant'
const MARKS: { value: Mark; labelKey: string; cls: string }[] = [
  { value: 'relevant', labelKey: 'markRelevant', cls: 'mark-rel' },
  { value: 'partial', labelKey: 'markPartial', cls: 'mark-par' },
  { value: 'irrelevant', labelKey: 'markIrrelevant', cls: 'mark-irr' },
]

export default function RateKeyword() {
  const { t, lang, user } = useStore()
  const r = useRating('keyword', keywordItems)
  const [marks, setMarks] = useState<Record<string, Mark>>({})
  const wm = watermarkOf(user?.email)

  if (!r.current) return <Completed />
  const item = r.current
  const dims = DIMENSIONS.keyword
  const dimsOk = dims.every((d) => r.scores[d] != null)

  const setMark = (id: string, m: Mark) =>
    setMarks((prev) => (prev[id] === m ? (({ [id]: _, ...rest }) => rest)(prev) : { ...prev, [id]: m }))

  return (
    <div className="page">
      <ProgressBar done={r.done} total={r.total} />

      <div className="query-banner">
        <span className="query-label">{t('keyword')}</span>
        <span className="query-text">“{item.query[lang]}”</span>
      </div>

      <p className="hint">{t('perImageHint')}</p>
      <div className="grid grid-2">
        {item.results.map((m, i) => (
          <div className="result-cell" key={m.id}>
            <div className="ranked">
              <span className="rank-badge">{i + 1}</span>
              <MediaTile media={m} watermark={wm} />
            </div>
            <div className="mark-row">
              {MARKS.map(({ value, labelKey, cls }) => (
                <button
                  key={value}
                  type="button"
                  className={`mark-btn ${cls} ${marks[m.id] === value ? 'active' : ''}`}
                  onClick={() => setMark(m.id, value)}
                >
                  {t(labelKey)}
                </button>
              ))}
            </div>
          </div>
        ))}
      </div>

      <DimensionList dims={dims} scores={r.scores} onScore={(k, v) => r.setScores({ ...r.scores, [k]: v })} />
      <SubmitBar
        canSubmit={dimsOk}
        onSubmit={() => { r.submit({ resultMarks: marks }); setMarks({}) }}
        onSkip={(reason) => { r.skip(reason); setMarks({}) }}
        freeText={r.freeText}
        setFreeText={r.setFreeText}
      />
    </div>
  )
}

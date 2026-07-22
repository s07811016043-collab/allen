import { MediaTile, ProgressBar, watermarkOf } from '../components'
import { DIMENSIONS, aestheticItems } from '../mock'
import { useStore } from '../store'
import { useRating } from './useRating'
import { Completed, DimensionList, SubmitBar } from './RateShared'

export default function RateAesthetic() {
  const { user } = useStore()
  const r = useRating('aesthetic', aestheticItems)
  const wm = watermarkOf(user?.email)

  if (!r.current) return <Completed />
  const dims = DIMENSIONS.aesthetic
  const dimsOk = dims.every((d) => r.scores[d] != null)

  return (
    <div className="page">
      <ProgressBar done={r.done} total={r.total} />
      <div className="hero-media">
        <MediaTile media={{ id: r.current.itemId, type: 'photo', url: r.current.imageUrl }} watermark={wm} big />
      </div>
      <DimensionList dims={dims} scores={r.scores} onScore={(k, v) => r.setScores({ ...r.scores, [k]: v })} />
      <SubmitBar
        canSubmit={dimsOk}
        onSubmit={() => r.submit()}
        onSkip={(reason) => r.skip(reason)}
        freeText={r.freeText}
        setFreeText={r.setFreeText}
      />
    </div>
  )
}

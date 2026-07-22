import { useMemo, useRef, useState } from 'react'
import { useStore } from '../store'
import type { AlgoType } from '../mock'

// Shared per-question flow: pick the next unrated item, collect dimension
// scores, stamp duration, and reset state between questions.
export function useRating<T extends { itemId: string }>(algo: AlgoType, items: T[]) {
  const { ratings, addRating } = useStore()
  const ratedIds = useMemo(() => new Set(ratings.filter((r) => r.algo === algo).map((r) => r.itemId)), [ratings, algo])
  const current = items.find((i) => !ratedIds.has(i.itemId))
  const done = items.length - (current ? items.filter((i) => !ratedIds.has(i.itemId)).length : 0)

  const [scores, setScores] = useState<Record<string, number>>({})
  const [freeText, setFreeText] = useState('')
  const startRef = useRef(Date.now())

  const reset = () => {
    setScores({})
    setFreeText('')
    startRef.current = Date.now()
  }

  const submit = (extra?: object) => {
    if (!current) return
    addRating({
      itemId: current.itemId,
      algo,
      scores,
      freeText: freeText || undefined,
      durationMs: Date.now() - startRef.current,
      ratedAt: new Date().toISOString(),
      ...extra,
    })
    reset()
  }

  const skip = (reason: string) => {
    if (!current) return
    addRating({
      itemId: current.itemId,
      algo,
      scores: {},
      skipped: reason,
      durationMs: Date.now() - startRef.current,
      ratedAt: new Date().toISOString(),
    })
    reset()
  }

  return { current, done, total: items.length, scores, setScores, freeText, setFreeText, submit, skip }
}

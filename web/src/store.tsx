import { createContext, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { detectLang, dicts } from './i18n'
import type { Lang } from './i18n'
import type { AlgoType } from './mock'

export interface RatingRecord {
  itemId: string
  algo: AlgoType
  scores: Record<string, number>
  resultMarks?: Record<string, 'relevant' | 'partial' | 'irrelevant'>
  userSelection?: string[]
  freeText?: string
  durationMs: number
  skipped?: string
  ratedAt: string
}

export interface Redemption {
  rewardId: string
  cost: number
  status: 'applied' | 'shipped'
  at: string
}

interface Store {
  lang: Lang
  setLang: (l: Lang) => void
  t: (key: string) => string
  user: { email: string; inviteCode: string } | null
  login: (email: string, inviteCode: string) => void
  logout: () => void
  ratings: RatingRecord[]
  addRating: (r: RatingRecord) => void
  points: number
  redemptions: Redemption[]
  redeem: (rewardId: string, cost: number) => boolean
}

const Ctx = createContext<Store>(null!)

function load<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : fallback
  } catch {
    return fallback
  }
}

export function StoreProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(detectLang)
  const [user, setUser] = useState<Store['user']>(() => load('user', null))
  const [ratings, setRatings] = useState<RatingRecord[]>(() => load('ratings', []))
  const [redemptions, setRedemptions] = useState<Redemption[]>(() => load('redemptions', []))

  useEffect(() => { localStorage.setItem('ratings', JSON.stringify(ratings)) }, [ratings])
  useEffect(() => { localStorage.setItem('redemptions', JSON.stringify(redemptions)) }, [redemptions])

  const setLang = (l: Lang) => {
    setLangState(l)
    localStorage.setItem('lang', l) // manual preference beats IP detection
  }

  const t = (key: string) => dicts[lang][key] ?? dicts.en[key] ?? key

  const login = (email: string, inviteCode: string) => {
    const u = { email, inviteCode }
    setUser(u)
    localStorage.setItem('user', JSON.stringify(u))
  }

  const logout = () => {
    setUser(null)
    localStorage.removeItem('user')
  }

  const addRating = (r: RatingRecord) => setRatings((prev) => [...prev, r])

  // PRD 5.8.1 — +10 per valid (non-skipped) rating, minus spent points.
  const earned = ratings.filter((r) => !r.skipped).length * 10
  const spent = redemptions.reduce((s, r) => s + r.cost, 0)
  const points = earned - spent

  const redeem = (rewardId: string, cost: number) => {
    if (points < cost) return false
    setRedemptions((prev) => [...prev, { rewardId, cost, status: 'applied', at: new Date().toISOString() }])
    return true
  }

  const value = useMemo(
    () => ({ lang, setLang, t, user, login, logout, ratings, addRating, points, redemptions, redeem }),
    [lang, user, ratings, redemptions, points],
  )
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export const useStore = () => useContext(Ctx)

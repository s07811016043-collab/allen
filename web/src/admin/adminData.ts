// Admin-side data layer (prototype): everything persists in localStorage so
// the C-side login can honor invite codes generated in the admin console.
import { aestheticItems, highlightItems, keywordItems, VALID_INVITE_CODES } from '../mock'
import type { AlgoType } from '../mock'

export interface InviteCode {
  code: string
  maxUse: number
  used: number
  status: 'active' | 'void'
  assignedTo?: string
  createdAt: string
}

export interface RosterUser {
  id: string
  email: string
  region: 'UK' | 'FR' | 'DE' | 'JP'
  code?: string
  sentAt?: string
}

export interface EmailLogEntry {
  at: string
  to: string[]
  subject: string
}

const K_CODES = 'adm_codes'
const K_ROSTER = 'adm_roster'
const K_EMAILS = 'adm_emails'
const K_BATCH = 'adm_batch_status'
export const K_ADMIN_SESSION = 'adm_session'

// Prototype-only credential check. Real deployments authenticate server-side.
export const ADMIN_EMAIL = '111@qq.com'
export const ADMIN_PASSWORD = '111'

export function load<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : fallback
  } catch {
    return fallback
  }
}
export function save(key: string, value: unknown) {
  localStorage.setItem(key, JSON.stringify(value))
}

export const loadCodes = () => load<InviteCode[]>(K_CODES, [])
export const saveCodes = (c: InviteCode[]) => save(K_CODES, c)
export const loadRoster = () => load<RosterUser[]>(K_ROSTER, [])
export const saveRoster = (r: RosterUser[]) => save(K_ROSTER, r)
export const loadEmails = () => load<EmailLogEntry[]>(K_EMAILS, [])
export const saveEmails = (e: EmailLogEntry[]) => save(K_EMAILS, e)
export const loadBatchStatus = () => load<Record<string, 'online' | 'offline'>>(K_BATCH, {})
export const saveBatchStatus = (s: Record<string, 'online' | 'offline'>) => save(K_BATCH, s)

export function randomCode(prefix: string) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  let s = ''
  for (let i = 0; i < 6; i++) s += chars[Math.floor(Math.random() * chars.length)]
  return `${prefix}-${s}`
}

// ---- C-side integration -------------------------------------------------

export function isValidInvite(code: string): boolean {
  const c = code.trim().toUpperCase()
  if (VALID_INVITE_CODES.includes(c)) return true
  const found = loadCodes().find((x) => x.code === c)
  return !!found && found.status === 'active' && found.used < found.maxUse
}

export function consumeInvite(code: string) {
  const c = code.trim().toUpperCase()
  if (VALID_INVITE_CODES.includes(c)) return
  const codes = loadCodes()
  const found = codes.find((x) => x.code === c)
  if (found) {
    found.used += 1
    saveCodes(codes)
  }
}

// ---- Model data batches (mirrors the mid-platform push, PRD 5.1) --------

export interface Batch {
  batchId: string
  algo: AlgoType
  modelVersion: string
  items: { itemId: string; thumb: string }[]
}

export const batches: Batch[] = [
  {
    batchId: 'batch-hl-20260720',
    algo: 'highlight',
    modelVersion: 'highlight-v1.2.0',
    items: highlightItems.map((i) => ({ itemId: i.itemId, thumb: i.highlightResult[0].url })),
  },
  {
    batchId: 'batch-ae-20260720',
    algo: 'aesthetic',
    modelVersion: 'aesthetic-v2.0.1',
    items: aestheticItems.map((i) => ({ itemId: i.itemId, thumb: i.imageUrl })),
  },
  {
    batchId: 'batch-kw-20260721',
    algo: 'keyword',
    modelVersion: 'search-v0.9.5',
    items: keywordItems.map((i) => ({ itemId: i.itemId, thumb: i.results[0].url })),
  },
]

// Rating stats read from the C-side store (same browser, prototype only)
export interface ItemStats { rated: number; avgOverall: number | null }

export function ratingStats(): Map<string, ItemStats> {
  const ratings = load<any[]>('ratings', [])
  const map = new Map<string, ItemStats>()
  for (const r of ratings) {
    if (r.skipped) continue
    const cur = map.get(r.itemId) ?? { rated: 0, avgOverall: null }
    const overallKey = Object.keys(r.scores).find((k) => k.endsWith('_overall'))
    const overall = overallKey ? r.scores[overallKey] : null
    const prevSum = (cur.avgOverall ?? 0) * cur.rated
    cur.rated += 1
    if (overall != null) cur.avgOverall = (prevSum + overall) / cur.rated
    map.set(r.itemId, cur)
  }
  return map
}

// Mock of data pushed by the algorithm mid-platform (PRD 5.1). In production
// these come from the ingestion service; the shapes mirror the push contract.

export type MediaType = 'photo' | 'video'

export interface MediaRef {
  id: string
  type: MediaType
  url: string
  poster?: string
  durationSec?: number
}

export interface HighlightItem {
  itemId: string
  sourceSet: MediaRef[]
  highlightResult: MediaRef[] // ordered, photos or video clips
}

export interface AestheticItem {
  itemId: string
  imageUrl: string
  // modelScore exists server-side but is never sent to the client (anchoring)
}

export interface KeywordItem {
  itemId: string
  query: Record<'en' | 'fr' | 'de' | 'ja', string>
  results: MediaRef[] // ordered by model relevance
}

// Self-contained placeholder "photos": seeded SVG gradients so the prototype
// needs no external image host (real assets come via signed CDN URLs).
const img = (seed: string, w = 640, h = 480) => {
  let hash = 0
  for (const c of seed) hash = (hash * 31 + c.charCodeAt(0)) >>> 0
  const h1 = hash % 360
  const h2 = (h1 + 40 + (hash >> 8) % 80) % 360
  const cx = 20 + ((hash >> 4) % 60)
  const cy = 25 + ((hash >> 6) % 50)
  const r = 12 + ((hash >> 10) % 18)
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 100 75">` +
    `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0" stop-color="hsl(${h1},65%,72%)"/>` +
    `<stop offset="1" stop-color="hsl(${h2},60%,48%)"/></linearGradient></defs>` +
    `<rect width="100" height="75" fill="url(#g)"/>` +
    `<circle cx="${cx}" cy="${cy}" r="${r}" fill="hsl(${h2},70%,85%)" opacity="0.55"/>` +
    `<circle cx="${100 - cx}" cy="${75 - cy}" r="${r * 0.7}" fill="hsl(${h1},70%,30%)" opacity="0.25"/>` +
    `<text x="50" y="40" font-size="7" font-family="sans-serif" fill="rgba(255,255,255,0.75)" text-anchor="middle">${seed}</text>` +
    `</svg>`
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
}

// Public sample clips (Google CDN) stand in for mid-platform video assets.
const SAMPLE_VIDEOS = [
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4',
  'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
]

export const highlightItems: HighlightItem[] = [0, 1, 2].map((n) => {
  const source: MediaRef[] = Array.from({ length: 8 }, (_, i) => ({
    id: `hl${n}-src${i}`,
    type: 'photo',
    url: img(`hl${n}-${i}`, 480, 360),
  }))
  source.push({
    id: `hl${n}-vid`,
    type: 'video',
    url: SAMPLE_VIDEOS[n % SAMPLE_VIDEOS.length],
    poster: img(`hl${n}-poster`, 480, 270),
    durationSec: 15,
  })
  return {
    itemId: `hl-${n}`,
    sourceSet: source,
    highlightResult: [source[2], source[5], source[8]], // 2 photos + the video
  }
})

export const aestheticItems: AestheticItem[] = Array.from({ length: 5 }, (_, n) => ({
  itemId: `ae-${n}`,
  imageUrl: img(`aesthetic-${n}`, 800, 600),
}))

export const keywordItems: KeywordItem[] = [
  {
    itemId: 'kw-0',
    query: { en: 'beach sunset', fr: 'coucher de soleil à la plage', de: 'Sonnenuntergang am Strand', ja: 'ビーチの夕日' },
    results: Array.from({ length: 8 }, (_, i) => ({
      id: `kw0-r${i}`, type: 'photo' as MediaType, url: img(`beach-${i}`, 480, 360),
    })),
  },
  {
    itemId: 'kw-1',
    query: { en: 'birthday cake', fr: 'gâteau d’anniversaire', de: 'Geburtstagstorte', ja: 'バースデーケーキ' },
    results: Array.from({ length: 8 }, (_, i) => ({
      id: `kw1-r${i}`, type: 'photo' as MediaType, url: img(`cake-${i}`, 480, 360),
    })),
  },
  {
    itemId: 'kw-2',
    query: { en: 'dog playing in snow', fr: 'chien jouant dans la neige', de: 'Hund spielt im Schnee', ja: '雪で遊ぶ犬' },
    results: Array.from({ length: 8 }, (_, i) => ({
      id: `kw2-r${i}`, type: 'photo' as MediaType, url: img(`dog-${i}`, 480, 360),
    })),
  },
]

export const DIMENSIONS = {
  highlight: ['q_hl_quality', 'q_hl_accuracy', 'q_hl_coverage', 'q_hl_order', 'q_hl_overall'],
  aesthetic: ['q_ae_composition', 'q_ae_color', 'q_ae_clarity', 'q_ae_content', 'q_ae_overall'],
  keyword: ['q_kw_relevance', 'q_kw_top', 'q_kw_ranking', 'q_kw_precision', 'q_kw_overall'],
} as const

export type AlgoType = keyof typeof DIMENSIONS

export const TASK_COUNTS: Record<AlgoType, number> = {
  highlight: highlightItems.length,
  aesthetic: aestheticItems.length,
  keyword: keywordItems.length,
}

export interface Reward {
  id: string
  nameKey: string
  cost: number
  stock: number
  emoji: string
}

export const rewards: Reward[] = [
  { id: 'tote', nameKey: 'reward_tote', cost: 80, stock: 50, emoji: '👜' },
  { id: 'tshirt', nameKey: 'reward_tshirt', cost: 150, stock: 30, emoji: '👕' },
  { id: 'giftcard', nameKey: 'reward_giftcard', cost: 300, stock: 20, emoji: '🎁' },
]

// One-per-person invite codes issued by ops (PRD 5.4.1). Mocked client-side.
export const VALID_INVITE_CODES = ['EVAL2026', 'STUDIO-UK', 'STUDIO-FR', 'STUDIO-DE', 'STUDIO-JP']

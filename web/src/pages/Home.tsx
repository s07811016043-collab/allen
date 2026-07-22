import { Link } from 'react-router-dom'
import { useStore } from '../store'
import { TASK_COUNTS } from '../mock'
import type { AlgoType } from '../mock'

const TASKS: { algo: AlgoType; icon: string; titleKey: string; descKey: string; path: string }[] = [
  { algo: 'highlight', icon: '✨', titleKey: 'algo_highlight', descKey: 'algo_highlight_desc', path: '/rate/highlight' },
  { algo: 'aesthetic', icon: '🖼️', titleKey: 'algo_aesthetic', descKey: 'algo_aesthetic_desc', path: '/rate/aesthetic' },
  { algo: 'keyword', icon: '🔍', titleKey: 'algo_keyword', descKey: 'algo_keyword_desc', path: '/rate/keyword' },
]

export default function Home() {
  const { t, ratings } = useStore()
  return (
    <div className="page">
      <h2>{t('taskListTitle')}</h2>
      <p className="sub">{t('taskListSub')}</p>
      <p className="notice">🔒 {t('noShare')}</p>
      <div className="task-list">
        {TASKS.map((task) => {
          const done = ratings.filter((r) => r.algo === task.algo).length
          const total = TASK_COUNTS[task.algo]
          const finished = done >= total
          return (
            <div className="card task-card" key={task.algo}>
              <div className="task-icon">{task.icon}</div>
              <div className="task-body">
                <h3>{t(task.titleKey)}</h3>
                <p>{t(task.descKey)}</p>
                <div className="task-meta">
                  <span className="chip">{done}/{total} {t('itemsDone')}</span>
                </div>
              </div>
              {finished ? (
                <span className="chip chip-done">✓</span>
              ) : (
                <Link className="btn btn-primary btn-sm" to={task.path}>
                  {done > 0 ? t('continueRating') : t('start')}
                </Link>
              )}
            </div>
          )
        })}
      </div>
      <p className="hint center">{t('dailyGoalHint')}</p>
    </div>
  )
}

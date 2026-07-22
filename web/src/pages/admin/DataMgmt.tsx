import { useState } from 'react'
import { batches, loadBatchStatus, ratingStats, saveBatchStatus } from '../../admin/adminData'

const ALGO_LABEL: Record<string, string> = {
  highlight: '高光时刻',
  aesthetic: '美学评分',
  keyword: '关键词搜索',
}

export default function DataMgmt() {
  const [status, setStatus] = useState(loadBatchStatus)
  const [openBatch, setOpenBatch] = useState<string | null>(null)
  const stats = ratingStats()

  const toggle = (batchId: string) => {
    const next = { ...status, [batchId]: (status[batchId] ?? 'online') === 'online' ? 'offline' as const : 'online' as const }
    setStatus(next)
    saveBatchStatus(next)
  }

  const exportRatings = () => {
    const raw = localStorage.getItem('ratings') ?? '[]'
    const lines = (JSON.parse(raw) as any[]).map((r) => JSON.stringify(r)).join('\n')
    const blob = new Blob([lines], { type: 'application/x-ndjson' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `ratings-export-${new Date().toISOString().slice(0, 10)}.jsonl`
    a.click()
    URL.revokeObjectURL(a.href)
  }

  return (
    <div>
      <div className="admin-page-head">
        <p className="hint">算法中台推送的评测批次(mock)。打分明细可导出为训练用 JSONL(PRD 5.7.2)。</p>
        <button className="btn btn-primary btn-sm" onClick={exportRatings}>导出打分明细 (JSONL)</button>
      </div>

      <div className="card admin-table-wrap">
        <table className="admin-table">
          <thead>
            <tr><th>批次</th><th>算法</th><th>模型版本</th><th>题目数</th><th>有效打分</th><th>状态</th><th></th></tr>
          </thead>
          <tbody>
            {batches.map((b) => {
              const rated = b.items.reduce((s, i) => s + (stats.get(i.itemId)?.rated ?? 0), 0)
              const online = (status[b.batchId] ?? 'online') === 'online'
              return (
                <tr key={b.batchId}>
                  <td className="mono">{b.batchId}</td>
                  <td>{ALGO_LABEL[b.algo]}</td>
                  <td className="mono">{b.modelVersion}</td>
                  <td>{b.items.length}</td>
                  <td>{rated}</td>
                  <td>
                    {online
                      ? <span className="badge badge-ok">进行中</span>
                      : <span className="badge badge-void">已下线</span>}
                  </td>
                  <td className="admin-actions">
                    <button className="btn btn-ghost btn-xs" onClick={() => toggle(b.batchId)}>
                      {online ? '下线' : '上线'}
                    </button>
                    <button className="btn btn-ghost btn-xs" onClick={() => setOpenBatch(openBatch === b.batchId ? null : b.batchId)}>
                      {openBatch === b.batchId ? '收起' : '查看题目'}
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {openBatch && (
        <div className="card">
          <h3>{openBatch} · 题目明细</h3>
          <div className="admin-item-grid">
            {batches.find((b) => b.batchId === openBatch)!.items.map((i) => {
              const s = stats.get(i.itemId)
              return (
                <div className="admin-item" key={i.itemId}>
                  <img src={i.thumb} alt="" />
                  <div>
                    <div className="mono">{i.itemId}</div>
                    <div className="hint">
                      有效打分 {s?.rated ?? 0} 次
                      {s?.avgOverall != null && ` · 总体均分 ${s.avgOverall.toFixed(1)}`}
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}

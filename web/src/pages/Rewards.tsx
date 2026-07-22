import { useState } from 'react'
import { useStore } from '../store'
import { rewards } from '../mock'

export default function Rewards() {
  const { t, points, redeem, redemptions } = useStore()
  const [toast, setToast] = useState('')

  const onRedeem = (id: string, cost: number) => {
    if (redeem(id, cost)) {
      setToast(t('redeemed'))
      setTimeout(() => setToast(''), 2500)
    }
  }

  return (
    <div className="page">
      <h2>{t('redeemTitle')}</h2>
      <p className="sub">{t('redeemSub')}</p>
      <div className="card points-card">
        <span>{t('myPoints')}</span>
        <strong>⭐ {points}</strong>
        <small className="hint">{t('pointsRule')}</small>
      </div>

      <div className="reward-list">
        {rewards.map((rw) => {
          const affordable = points >= rw.cost
          return (
            <div className="card reward-card" key={rw.id}>
              <span className="reward-emoji">{rw.emoji}</span>
              <div className="reward-body">
                <h3>{t(rw.nameKey)}</h3>
                <span className="chip">{rw.cost} {t('cost')}</span>
              </div>
              <button
                className="btn btn-primary btn-sm"
                disabled={!affordable || rw.stock <= 0}
                onClick={() => onRedeem(rw.id, rw.cost)}
              >
                {rw.stock <= 0 ? t('outOfStock') : affordable ? t('redeem') : t('notEnough')}
              </button>
            </div>
          )
        })}
      </div>

      {redemptions.length > 0 && (
        <>
          <h3 className="section-title">{t('myRedemptions')}</h3>
          {redemptions.map((rd, i) => {
            const rw = rewards.find((x) => x.id === rd.rewardId)
            return (
              <div className="card redemption-row" key={i}>
                <span>{rw?.emoji} {rw ? t(rw.nameKey) : rd.rewardId}</span>
                <span className="chip">{rd.status === 'applied' ? t('statusApplied') : t('statusShipped')}</span>
              </div>
            )
          })}
        </>
      )}
      {toast && <div className="toast">{toast}</div>}
    </div>
  )
}

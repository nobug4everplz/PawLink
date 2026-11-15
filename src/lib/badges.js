import { reactive } from 'vue'
import { auth } from './auth'
import { getReportInbox, getAnimalAlerts, getShifts, getTnrTasks, getAdoptions } from './api'

/**
 * 底部分頁列與「我的」頁共用的待辦數字。
 * inbox：我照顧的點還沒處理的居民通報，加上還沒處理的動物提醒
 * shifts：我照顧的點有別人在求代班的班數
 * tnr：我認領的 TNR 任務裡，現在輪到我做的
 * adopt：null 表示沒有跟我有關的領養紀錄；數字是待填問卷加上等我確認的登記
 */
export const badges = reactive({ inbox: 0, shifts: 0, tnr: 0, adopt: null })

let seq = 0
export async function refreshBadges() {
  const my = ++seq
  if (!auth.user) { Object.assign(badges, { inbox: 0, shifts: 0, tnr: 0, adopt: null }); return }
  try {
    const [reports, alerts, shifts, tnr, ad] = await Promise.all([
      getReportInbox({ silent: true }), getAnimalAlerts({ silent: true }),
      getShifts({ silent: true }), getTnrTasks(null, { silent: true }), getAdoptions(null, { silent: true }),
    ])
    if (my !== seq) return
    badges.inbox = (reports || []).filter((r) => r.status === 'open').length + (alerts || []).filter((a) => a.status === 'open').length
    badges.shifts = (shifts || []).filter((x) => x.can_claim).length
    badges.tnr = (tnr || []).filter((t) => t.is_mine && t.is_ready).length
    badges.adopt = ad?.length ? ad.reduce((n, r) => n + (r.my_role === 'adopter' ? r.due_count : r.my_role === 'caretaker' ? 1 : 0), 0) : null
  } catch (e) { console.warn('待辦數字載入失敗', e) }
}

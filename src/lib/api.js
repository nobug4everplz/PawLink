import { supabase } from './supabase'
import { mockSpots } from './mockSpots'
import { auth } from './auth'
import { enqueueFeeding, isNetworkError } from './offlineQueue'
import { cachedSpot } from './spots'

function need() {
  if (!supabase) throw new Error('尚未設定 Supabase（請填 .env）')
  return supabase
}
async function rpc(name, args) {
  const { data, error } = await need().rpc(name, args)
  if (error) throw error
  return data
}

export async function getSpotSummary(id) {
  if (!supabase) {
    const s = mockSpots.find((x) => x.id === id)
    return { ...s, description: null, is_caretaker: false, feedings_30d: 0, cleaned_30d: 0, caretaker_count: 0 }
  }
  try {
    const rows = await rpc('get_spot_summary', { p_spot_id: id })
    return Array.isArray(rows) ? rows[0] : rows
  } catch (e) {
    // 離線時用地圖上次載入的資料頂著，至少看得到名稱、能記錄餵食
    const c = isNetworkError(e) ? cachedSpot(id) : null
    if (c) return { ...c, description: null, is_caretaker: true, offline: true }
    throw e
  }
}
export const findNearbySpots = (lat, lng) => rpc('find_nearby_spots', { p_lat: lat, p_lng: lng })
export const createSpot = (name, lat, lng, description) =>
  rpc('create_feeding_spot', { p_name: name, p_lat: lat, p_lng: lng, p_description: description || null })
export async function joinSpot(spotId, userId) {
  const { error } = await need().from('spot_caretakers').insert({ spot_id: spotId, user_id: userId })
  if (error && error.code !== '23505') throw error
}
export const checkRecentFeeding = (spotId) => rpc('check_recent_feeding', { p_spot_id: spotId })
/**
 * 記錄餵食。沒有網路時先存在手機，回傳 { queued: true }，恢復連線後由 offlineQueue 補傳。
 * client_id 在這裡就產生：就算請求其實有送到、只是回應沒收到，補傳時伺服器也會認出是同一筆。
 */
export async function recordFeeding(spotId, foodType, note) {
  const item = { client_id: crypto.randomUUID(), spot_id: spotId, food_type: foodType, note: note || null, fed_at: new Date().toISOString(), user_id: auth.user?.id }
  const queue = async () => { await enqueueFeeding(item); return { queued: true } }
  if (supabase && auth.user && !navigator.onLine) return queue()
  try {
    await rpc('record_feeding', { p_spot_id: spotId, p_food_type: foodType, p_note: item.note, p_fed_at: item.fed_at, p_client_id: item.client_id })
    return { queued: false }
  } catch (e) {
    if (auth.user && isNetworkError(e)) return queue()
    throw e
  }
}
export const reportCleanup = (logId) => rpc('report_cleanup', { p_log_id: logId })
export const getPendingCleanups = () => rpc('get_my_pending_cleanups')

export async function listSpotAnimals(spotId) {
  if (!supabase) return []
  const { data, error } = await supabase
    .from('spot_animals')
    .select('animal:animals(id,name,species,tnr_stage,is_sterilized,animal_photos!animal_photos_animal_id_fkey(storage_path,created_at))')
    .eq('spot_id', spotId)
  if (error) throw error
  return data.map((r) => r.animal)
}
export async function getAnimal(id) {
  const { data, error } = await need()
    .from('animals')
    .select('*, animal_photos!animal_photos_animal_id_fkey(id,storage_path,created_at), spot_animals(spot_id)')
    .eq('id', id).single()
  if (error) throw error
  return data
}
export async function createAnimal(spotId, fields) {
  const { data, error } = await need().from('animals').insert(fields).select().single()
  if (error) throw error
  const link = await need().from('spot_animals').insert({ spot_id: spotId, animal_id: data.id })
  if (link.error) throw link.error
  return data
}
// tnr_updated_at 由資料庫 trigger 自動更新，前端沒有該欄位的寫入權，不可一併送出
export async function updateTnrStage(animalId, stage) {
  const { data, error } = await need().from('animals').update({ tnr_stage: stage }).eq('id', animalId).select('id')
  if (error) throw error
  // 沒有權限時 RLS 不會回錯誤，只是更新 0 筆
  if (!data.length) throw new Error('只有建立者、該餵食點的照顧者或管理員可以更新')
}
/** 目前登入者能不能編輯這隻動物（與資料庫 can_edit_animal 規則一致，僅用於介面顯示） */
export async function canEditAnimal(animal, user, isAdmin) {
  if (!user) return false
  if (isAdmin || animal.created_by === user.id) return true
  const spotIds = (animal.spot_animals || []).map((x) => x.spot_id)
  if (!spotIds.length) return false
  const { data } = await need().from('spot_caretakers').select('spot_id').eq('user_id', user.id).in('spot_id', spotIds).limit(1)
  return !!data?.length
}
export async function uploadAnimalPhoto(animalId, blob) {
  const ext = blob.type === 'image/jpeg' ? 'jpg' : 'webp'
  const path = `${animalId}/${crypto.randomUUID()}.${ext}`
  const up = await need().storage.from('animal-photos').upload(path, blob, { contentType: blob.type })
  if (up.error) throw up.error
  const { error } = await need().from('animal_photos').insert({ animal_id: animalId, storage_path: path })
  if (error) throw error
  return path
}
export const photoUrl = (path) => supabase?.storage.from('animal-photos').getPublicUrl(path).data.publicUrl

export function subscribeFeeding(onChange) {
  if (!supabase) return () => {}
  const ch = supabase.channel('feeding-logs')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'feeding_logs' }, (p) => onChange(p.new?.spot_id))
    .subscribe()
  return () => supabase.removeChannel(ch)
}

// ---------- 階段 2：保育熱區與三層警示 ----------
// 讀取類的呼叫失敗時（例如資料庫還沒套用階段 2 的 migration）一律當成「沒有熱區」，不影響原有流程

/** 使用中的保育熱區（含 200 公尺緩衝帶 GeoJSON） */
export async function getZones() {
  if (!supabase) return []
  try { return await rpc('get_conservation_zones') } catch (e) { console.warn('保育熱區載入失敗', e); return [] }
}
/** 座標的警示：{ level: 'red' | 'yellow' | 'none', zone_name, species, distance_m, is_demo }，查不到回 null */
export async function checkAlert(lat, lng) {
  if (!supabase) return null
  try { return (await rpc('check_conservation_alert', { p_lat: lat, p_lng: lng }))?.[0] ?? null }
  catch (e) { console.warn('保育警示檢查失敗', e); return null }
}
/** 既有餵食點的警示（需登入） */
export async function checkSpotAlert(spotId) {
  if (!supabase) return null
  try { return (await rpc('check_spot_conservation_alert', { p_spot_id: spotId }))?.[0] ?? null }
  catch (e) { console.warn('保育警示檢查失敗', e); return null }
}
export const saveZone = (z) => rpc('save_conservation_zone', {
  p_name: z.name, p_geojson: z.geojson, p_species: z.species || null,
  p_description: z.description || null, p_is_demo: z.is_demo, p_id: z.id || null,
})
export async function deleteZone(id) {
  const { data, error } = await need().from('conservation_zones').delete().eq('id', id).select('id')
  if (error) throw error
  if (!data.length) throw new Error('只有管理員可以刪除保育熱區')
}

// ---------- 階段 2：管理員後台 ----------
export const adminListUsers = (search) => rpc('admin_list_users', { p_search: search || null })
export const setUserRole = (userId, role) => rpc('set_user_role', { p_user_id: userId, p_role: role })
export const adminListSpots = (search) => rpc('admin_list_spots', { p_search: search || null })
export const adminSetSpotOwner = (spotId, userId) => rpc('admin_set_spot_owner', { p_spot_id: spotId, p_user_id: userId })
export async function setSpotStatus(spotId, status) {
  const { data, error } = await need().from('feeding_spots').update({ status }).eq('id', spotId).select('id')
  if (error) throw error
  if (!data.length) throw new Error('沒有權限修改這個餵食點')
}
/** 管理員：全部熱區（含停用），不含範圍幾何 */
export async function adminListZones() {
  const { data, error } = await need().from('conservation_zones')
    .select('id,name,species,description,is_demo,status,updated_at').order('status').order('name')
  if (error) throw error
  return data
}
export async function setZoneStatus(id, status) {
  const { data, error } = await need().from('conservation_zones').update({ status }).eq('id', id).select('id')
  if (error) throw error
  if (!data.length) throw new Error('只有管理員可以修改保育熱區')
}

// ---------- 階段 3：匿名通報、收件匣、進度公開 ----------
export const REPORT_CATEGORY = { mess: '環境髒亂', noise: '噪音', gathering: '動物聚集', timing: '餵食時間不當', other: '其他' }
export const REPORT_STATUS = { open: ['待處理', 'danger'], acknowledged: ['處理中', 'warning'], resolved: ['已處理', 'success'] }

export const submitReport = (spotId, category, description, token) =>
  rpc('submit_neighbor_report', { p_spot_id: spotId, p_category: category, p_description: description, p_turnstile_token: token || null })
export async function reportCaptchaRequired() {
  try { return !!(await rpc('report_captcha_required')) } catch { return false }
}
/** 公開的通報處理進度（不含通報內容）。資料庫還沒套用階段 3 時回空陣列 */
export async function getSpotPublicReports(spotId) {
  if (!supabase) return []
  try { return await rpc('get_spot_public_reports', { p_spot_id: spotId }) } catch (e) { console.warn('通報進度載入失敗', e); return [] }
}
/** 我照顧的點收到的通報（管理員為全部）。失敗時回空陣列，不影響地圖 */
export async function getReportInbox({ silent = false } = {}) {
  if (!supabase) return []
  try { return await rpc('get_my_report_inbox') } catch (e) { if (!silent) throw e; return [] }
}
export const handleReport = (id, status, response) =>
  rpc('handle_neighbor_report', { p_report_id: id, p_status: status, p_response: response || null })

// ---------- 階段 3：交流空間 ----------
export async function listPosts() {
  const { data, error } = await need().from('posts')
    .select('id,title,body,status,created_at,author_id,author:profiles(display_name),comments(count)')
    .order('created_at', { ascending: false }).limit(100)
  if (error) throw error
  return data
}
export async function getPost(id) {
  const { data, error } = await need().from('posts')
    .select('id,title,body,status,created_at,author_id,author:profiles(display_name)').eq('id', id).maybeSingle()
  if (error) throw error
  return data
}
export async function listComments(postId) {
  const { data, error } = await need().from('comments')
    .select('id,body,status,created_at,author_id,author:profiles(display_name)').eq('post_id', postId).order('created_at')
  if (error) throw error
  return data
}
export async function createPost(title, body) {
  const { data, error } = await need().from('posts').insert({ title, body }).select('id').single()
  if (error) throw error
  return data.id
}
export async function createComment(postId, body) {
  const { error } = await need().from('comments').insert({ post_id: postId, body })
  if (error) throw error
}
export async function deletePost(id) {
  const { data, error } = await need().from('posts').delete().eq('id', id).select('id')
  if (error) throw error
  if (!data.length) throw new Error('只有作者或管理員可以刪除')
}
export async function deleteComment(id) {
  const { data, error } = await need().from('comments').delete().eq('id', id).select('id')
  if (error) throw error
  if (!data.length) throw new Error('只有作者或管理員可以刪除')
}
/** 檢舉貼文或留言；重複檢舉會提示已檢舉過 */
export async function flagContent(target, reason) {
  const { error } = await need().from('content_flags').insert({ ...target, reason })
  if (error?.code === '23505') throw new Error('你已經檢舉過這則內容')
  if (error) throw error
}
export const adminListFlags = () => rpc('admin_list_flags')
export const moderateContent = (type, id, hide) => rpc('moderate_content', { p_target_type: type, p_target_id: id, p_hide: hide })

// ---------- 階段 5 延伸一：失蹤／健康哨兵（FR-4.2） ----------
export const SIGHTING_CONDITION = { normal: '看起來正常', limping: '跛腳', thin: '消瘦', injured: '受傷' }
export const reportSighting = (animalId, condition, note, spotId) =>
  rpc('report_sighting', { p_animal_id: animalId, p_condition: condition, p_spot_id: spotId || null, p_note: note || null })
/** 還沒套用哨兵的資料庫時回傳 null，畫面就不顯示這一區 */
export async function getAnimalSightings(animalId) {
  try { return await rpc('get_animal_sightings', { p_animal_id: animalId, p_limit: 10 }) } catch { return null }
}
export async function getAnimalAlerts({ silent = false } = {}) {
  if (!supabase) return []
  try { return await rpc('get_my_animal_alerts') } catch (e) { if (!silent) throw e; return [] }
}
export const resolveAnimalAlert = (id, note, markMissing = false) =>
  rpc('resolve_animal_alert', { p_alert_id: id, p_note: note || null, p_mark_missing: markMissing })
export const adminRunSentinel = (run = true) => rpc('admin_run_sentinel', { p_run: run })

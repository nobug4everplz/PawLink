import { supabase } from './supabase'
import { mockSpots } from './mockSpots'

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
  const rows = await rpc('get_spot_summary', { p_spot_id: id })
  return Array.isArray(rows) ? rows[0] : rows
}
export const findNearbySpots = (lat, lng) => rpc('find_nearby_spots', { p_lat: lat, p_lng: lng })
export const createSpot = (name, lat, lng, description) =>
  rpc('create_feeding_spot', { p_name: name, p_lat: lat, p_lng: lng, p_description: description || null })
export async function joinSpot(spotId, userId) {
  const { error } = await need().from('spot_caretakers').insert({ spot_id: spotId, user_id: userId })
  if (error && error.code !== '23505') throw error
}
export const checkRecentFeeding = (spotId) => rpc('check_recent_feeding', { p_spot_id: spotId })
export const recordFeeding = (spotId, foodType, note) =>
  rpc('record_feeding', { p_spot_id: spotId, p_food_type: foodType, p_note: note || null, p_client_id: crypto.randomUUID() })
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

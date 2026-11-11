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
